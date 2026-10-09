# Operations and upgrades

Use the [README](../README.md) for the two-step first deployment and teardown.
This guide covers troubleshooting and changes to an existing deployment.
Review a saved Terraform plan before applying upgrades, and follow
[the deployment test checklist](testing.md) in a disposable environment first.

## PostgreSQL credential ownership and adoption

Terraform owns `random_password.postgresql_user`,
`random_password.postgresql_admin`, and `kubernetes_secret.postgresql` in
`helm.tf`. The Secret is named `fortiaigate-postgresql`;
`local.db_auth_values` sets `postgresql.auth.existingSecret` so the chart uses it.

PostgreSQL stores passwords in its data directory at initialization. Its data
PVC can survive a Helm uninstall, while a chart-generated Secret may disappear.
Reinstalling with newly generated passwords against retained data causes
`password authentication failed` in API, core, and logd. Terraform ownership
keeps the credential lifetime independent of the Helm release.

The password resources use `ignore_changes = all`. Rotating a password requires
coordinating the Secret with `ALTER ROLE` inside PostgreSQL. The Secret's
`helm.sh/resource-policy: keep` annotation protects it when an upgrade removes
the previously chart-owned Secret from the release manifest.

For an existing deployment whose Secret was created by Helm, import its current
passwords and Secret **before applying** the Terraform ownership change. Replace
the tfvars path and namespace below to match the deployment:

```bash
terraform import -var-file=tfvars/dev.tfvars random_password.postgresql_user "$(kubectl -n fortiaigate get secret fortiaigate-postgresql -o jsonpath='{.data.password}' | base64 -d)"
terraform import -var-file=tfvars/dev.tfvars random_password.postgresql_admin "$(kubectl -n fortiaigate get secret fortiaigate-postgresql -o jsonpath='{.data.postgres-password}' | base64 -d)"
terraform import -var-file=tfvars/dev.tfvars kubernetes_secret.postgresql fortiaigate/fortiaigate-postgresql
```

Run credential imports in a private terminal; the import IDs contain passwords.
If a failed apply already recorded newly generated password resources, first
back up state and inspect those entries. Remove only the incorrect
`random_password.postgresql_user` and `random_password.postgresql_admin` entries
from state before importing the live values. Do not remove the live database or
Secret. The credential-adoption plan should preserve both passwords and show
only the expected Secret metadata and Helm release updates. Investigate any
password replacement or unexpected pod rollout before applying.

## Node-keyed licensing

`var.licenses` maps actual AKS node names to local license files. `licenses.tf`
loads them into `fortiaigate-license-config`. The license-manager DaemonSet
delivers each node's license, and workload pods use required hostname affinity
to licensed nodes. Triton also requires the GPU node selector and toleration.

Discover both app and GPU node names between the two bootstrap applies and
include their licenses before the full apply. Adding unlicensed nodes does not
increase usable workload capacity. Size `app_node_count` to the app-node license
count, and ensure the licensed nodes have enough CPU, memory, and pod capacity.
The default `app_node_max_pods` is 110; an exhausted pod cap or hostname mismatch
can leave workloads Pending. Inspect scheduling events and node allocation.

Node-pool replacement, repair, or upgrades can change hostnames. After pool
churn, compare `kubectl get nodes` with `var.licenses`, obtain matching licenses
as needed, and reapply. See [GPU compatibility](gpu-triton-compatibility.md) for
GPU sizing and pool replacement.

A license can remain in `License status: In Use` after the prior deployment's
nodes are removed. Core returns readiness HTTP 503 while the license is
unavailable, so Helm and Terraform may time out despite healthy infrastructure.
Previous deployments observed release within roughly 24 hours; verify the seat
status in FortiFlex/FortiCare and release it manually there if necessary.

Changing license file contents updates `license.checksum` and rolls
license-manager. Editing its ConfigMap alone does not trigger that rollout.

## Storage and immutable settings

The shared PVC requires ReadWriteMany and uses Azure Files. PostgreSQL and Redis
use dedicated ReadWriteOnce Azure Disks through `local.db_storage_values` in
`helm.tf` and `var.db_storage_class` (default `managed-csi`). PostgreSQL's data
directory needs permissions, locking, and filesystem behavior that the shared
SMB claim cannot provide; using it can fail during `initdb`.

Changing a database StatefulSet from an existing claim to a volume claim
template, or changing `db_storage_class`, requires a planned StatefulSet and
data migration because `volumeClaimTemplates` is immutable. Before the first
successful database initialization, recreation may be sufficient; populated
deployments require backup and restore or migration. Do not delete data PVCs
as a troubleshooting shortcut.

The shared PVC's StorageClass cannot be changed in place, and its requested
size cannot be shrunk. Expansion is supported by the configured StorageClass.
Choose storage settings before deploying, or plan a migration.

`local.storage_account_name` derives a lowercase alphanumeric name from
`cluster_name` plus a random suffix, truncated to 24 characters. Changing
`cluster_name` can change that name and cause storage account replacement.
The suffix resource has no cluster-name keeper. Inspect replacement plans and
migrate shares before replacing an account that contains data. The StorageClass
uses `Retain`, but destroying the account still removes its shares; see
[README teardown](../README.md#teardown).

## Helm value precedence and rollouts

`helm.tf` merges extra values files first, then generated GPU, database storage,
database authentication, private gateway, gateway trusted root, ingress
annotation, TLS, and license placement values. Later entries take precedence;
Terraform `set` blocks override the merged values. Check the actual `values =
concat(...)` and `set` blocks when adding overrides.

`deployment.chartRevision` is a chart digest that forces Helm to notice local
chart edits; templates do not use it to restart pods. Pod rollouts follow pod
spec changes or checksums for web TLS, internal TLS, and licenses. Web
certificate replacement rolls core/API/webui without rolling databases,
scanners, logd, or license-manager. Let's Encrypt renewals use Reloader.
See [supplied TLS upgrade notes](tls-supplied.md#renewal-and-upgrades) for the
separate internal Secret and the database TLS transition.

Keep `gpu_driver = "Install"` explicit in `aks.tf`. Omitting it has previously
caused a provider plan to replace the GPU pool, changing its hostname and
breaking license placement. Investigate unexpected node-pool replacement on
every upgrade plan.

## Recovering a partial bootstrap

If a failed first apply left networking incomplete and AKS reports subnet
validation errors, inspect the failed resources and finish the subnet targets
before retrying the README bootstrap:

```bash
terraform apply -target=azurerm_subnet.aks -target=azurerm_subnet.appgw -var-file=tfvars/dev.tfvars
```

Both subnet resources are kept even when AGIC is disabled so toggling ingress
does not require adding or removing subnet references. For gateway ownership,
AGIC-managed blocks, and backend readiness probes, use
[the gateway guide](application-gateway-dns-tls.md) and
[Let's Encrypt troubleshooting](tls-letsencrypt.md#notes-and-caveats).
