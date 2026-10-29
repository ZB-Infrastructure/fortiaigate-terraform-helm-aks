# Testing and distribution checklist

## Offline checks

Use Terraform, Helm 3, Python 3.10+, and TFLint v0.53.0 as described in
[CONTRIBUTING.md](../CONTRIBUTING.md). Run checks from a clean checkout so local
tfvars and initialized remote state do not affect results:

```bash
terraform fmt -check -recursive
terraform init -backend=false -lockfile=readonly
terraform validate
tflint --init
tflint --recursive --format compact
python3 -m pip install -r tests/requirements.txt
python3 -m unittest discover -s tests -v
python3 scripts/test_tls.py # Terraform 1.7+; mocked tests in an isolated checkout
python3 tests/check_gpu_tuning.py
python3 scripts/check_docs.py
terraform-docs .
```

The Helm suite renders representative AKS values and checks CPU/GPU behavior,
deployment licensing and app/GPU placement, independent app/Triton image tags, backend readiness
paths, separate database disks,
shared/dedicated inference topology, separate web/internal TLS secrets and rollout checksums, and staging/production Certificate resources.
The certificate preflight tests use real temporary keys/certificates. The mocked
Terraform suite covers generated, supplied public/private, and Let's Encrypt
modes, as well as invalid input combinations.
It also verifies missing issuer inputs fail rendering. It uses the committed
subcharts without refreshing dependencies. The GPU composition check evaluates actual Terraform profile/overlay/tuning
values and renders them through Helm for A10, other-card, CPU, and explicit-override
cases. Mocked tests also cover external networking and PostgreSQL certificate
username precedence. These checks do not exercise Azure permissions, image availability, admission controllers, or actual
certificate issuance.

## Live deployment tests

Previous repository notes recorded a clean 8.0.0 deployment on 2026-05-28 using
AKS 1.35, one licensed app node with a 110-pod cap, one A10 GPU node, and
PostgreSQL on `managed-csi`. This is historical evidence for that configuration;
it does not validate the 8.0.1/build0031 chart or the current TLS changes.

Use a dedicated test subscription/resource group and follow the README's
two-step bootstrap. These operations create billable Azure resources.

1. Check regional AKS version availability, GPU quota, image availability, and
   principal permissions. Set `acr_id` if this stack should manage image pull access.
2. Start with CPU-only (`gpu_enabled = false`) and an app node. Verify
   all pods become ready, shared and database PVCs bind, and `/ui` is reachable.
   Self-signed TLS requires explicit Application Gateway backend trust; follow
   [the TLS guide](application-gateway-dns-tls.md) before diagnosing HTTP 502s.
3. Enable the GPU pool using the bootstrap targets, choose shared/dedicated topology and sufficient GPU capacity
   before the full apply. Verify Triton schedules on
   the GPU pool and both DLP and POLICY requests complete; check
   license onboarding, metering, model loading, device visibility, and memory.
4. Run a second plan with the same tfvars. Investigate unexpected replacement or
   perpetual updates, especially GPU nodes and storage. The GPU minimum is now
   one while enabled, preserving the node during idle/bootstrap periods and
   continuing to incur its VM cost. Node repair/upgrade can still replace it.
5. Exercise Let's Encrypt staging then production in a disposable DNS name.
   Upload the deployment license through the admin API. Confirm Certificate
   readiness, gateway health, and pod reload after secret
   changes. Verify PostgreSQL/Redis TLS with the internal leaf and generated CA. Test supplied
   public/private certificates and replacement using [the supplied TLS guide](tls-supplied.md).
   Verify gateway/API-to-guardrail and license-manager RPC/database trust when
   web and internal certificates have different issuers.
6. Back up and restore database data and the shared file data. Test a node
   replacement and deployment license coverage before planning a production upgrade.
7. Follow [staged teardown](teardown.md); check for remaining disks/shares and
   confirm retained data matches expectations before deleting the resource group.

For the current image set and upgrade expectations, use [build0055 port notes](build0055-compatibility.md).

## Existing deployment review

Use the [8.0.1-to-8.0.2 upgrade guide](upgrade-8.0.1-to-8.0.2.md) for the
branch comparison, staged secret adoption, and rehearsal/recovery checklist.
That documentation does not establish a qualified live upgrade.

Build0047 targets fresh installations. Database migration and conversion from
node-keyed licensing are not qualified; use [the compatibility audit](build0047-compatibility.md).

Review a saved plan before applying changes. Application services, licensing,
encryption, and ingress routes change with build0047. Existing PVCs and database
schemas are not migrated by this port. Retain credential resource addresses,
back up data and keys, and qualify application schema/license conversion before
reusing old storage. Each ingress backend has a different readiness endpoint;
remove global AGIC probe-path overrides from local tfvars. Terraform passes a
chart digest, including files used by the GPU probe, so local edits produce an
upgrade plan. Offline suites cannot confirm runtime scanning or data migration.

Azure behavior references: [cluster autoscaler](https://learn.microsoft.com/en-us/azure/aks/cluster-autoscaler-overview)
and [Azure Files CSI provisioning](https://learn.microsoft.com/en-us/azure/aks/azure-csi-files-storage-provision).

## Distribution

Distribute a reviewed Git commit/tag, including `.terraform.lock.hcl`, the Helm
lockfile, and vendored subcharts. Use placeholder tfvars examples; exclude local
licenses, keys, kubeconfigs, state, plans, and rendered manifests. Build source
archives from committed files (`git archive`) rather than archiving the working
directory. Record the tested Azure region, AKS version, image tag, TLS mode,
CPU/GPU results, and known limitations in the release notes.

## Historical build0047 offline port status

The AKS port preserves app/GPU placement, database disks, Terraform-owned
credentials/encryption/CSRF, and independent web/internal TLS. Tests cover new
ingress routes and probes, shared/dedicated GPU shapes, image defaults, legacy
license rejection, and explicit GPU capacity. No live AKS results are recorded
for build0047. CPU-only POLICY detectors fail closed without vLLM; do not treat
a successful CPU render as proof of full scanning capability.

On 2026-10-09 the port passed 19 Python/Helm/certificate tests, 15 mocked
Terraform runs, isolated Terraform validation, TFLint 0.53.0/Azure ruleset 0.27.0,
formatting, documentation link checks, and proxy/GPU-probe syntax checks.
Existing Azure provider deprecation warnings are still present.

## Historical existing network validation

On 2026-10-12, existing-network support on `main` passed isolated Terraform
validation, 18 mocked Terraform runs (including eight network scenarios),
14 Python/Helm/certificate tests using vendored subcharts, TFLint 0.53.0 with
Azure ruleset 0.27.0, and Terraform formatting. The network scenarios cover
managed defaults, external public/private gateways, AGIC disabled, app/GPU
subnet placement, service/DNS overrides, and incomplete or inconsistent IDs.
The existing test runner supplies a user-assigned identity/kubelet fixture
because mocked plans do not populate AKS's optional kubelet block; it does not
prove Azure identity creation or permission propagation.

No live deployment was performed for this feature. Qualify external network
RBAC, gateway connectivity, existing NSGs/routes/DNS, IP capacity, a second
plan, and teardown that preserves external networking in a dedicated test
environment using [the existing network guide](existing-network.md).

## Build0055 validation

The current branch uses build0055. The build0047 results above are historical.
No live build0055 AKS deployment, model execution, database migration, or staged
teardown is recorded. Qualification must cover the independent internal leaf,
PostgreSQL certificate authentication, A10 startup/VRAM budgets, supplied and
cert-manager TLS renewal, retained credentials/data, external network RBAC,
second-plan stability, and controller/storage cleanup.

On 2026-10-27 the build0055 port passed isolated Terraform validation and
formatting, 35 mocked Terraform runs (10 GPU, eight network, 17 TLS/release),
20 Python/Helm/real-certificate tests, four Terraform-to-Helm GPU composition
cases, TFLint 0.53.0 with Azure ruleset 0.27.0, local Markdown link checks,
reproducible Terraform reference generation, UI proxy syntax, and GPU probe
syntax checks. Provider binaries came from the existing lockfile/cache; no
backend, local tfvars, deployment state, Azure API, or Kubernetes cluster was
used. Existing Azure provider deprecation warnings remain. Existing Terraform
resource declarations were preserved; only the three internal leaf/key/CSR
resources were added. These offline results do not establish runtime or
migration compatibility.

## Public gateway backend trust

On 2026-10-29, automatic public gateway trust-root configuration passed isolated
Terraform validation, 37 mocked Terraform runs, 20 Python/Helm/certificate tests,
four Terraform-to-Helm GPU cases, TFLint 0.53.0 with Azure ruleset 0.27.0,
formatting, and local documentation links.
The new checks cover generated and supplied private roots on the public add-on
gateway, the actual gateway ID returned by AKS, the limited update body,
configuration for name-based certificate merging, and the ingress trust
annotation. They also
check that private gateways retain AzureRM ownership and that publicly trusted
certificates, Let's Encrypt, and AGIC-disabled deployments omit the new update.

These are offline results; AzAPI is mocked during the Terraform runs. Before
production rollout, qualify a public gateway in a dedicated Azure environment:

1. Apply with generated web TLS and check that `fortiaigate-ca` appears in the
   gateway's trusted roots and is selected in its HTTPS backend settings.
   Verify healthy backends and UI/API access without HTTP 502 responses.
2. Repeat with a supplied private CA and then a publicly trusted certificate.
   Verify CA changes update the named root and the annotation follows the
   selected certificate mode. Clients must trust private CAs separately.
3. Confirm a second plan is clean, unrelated roots and AGIC routing survive
   the update, and an AGIC reconciliation preserves the uploaded root.
4. Exercise add-on/CA updates and gateway recreation. If Azure rejects an
   overlapping gateway operation, let the active operation finish and re-plan
   before retrying. AzAPI's update reads and merges the gateway configuration;
   it does not lock out the AGIC controller.
5. Verify teardown leaves externally owned networking intact. Removing the
   AzAPI update itself leaves its root certificate on the gateway; see
   [gateway TLS lifecycle](application-gateway-dns-tls.md#tls-options).

No live Azure deployment or gateway health check was performed for this change.
