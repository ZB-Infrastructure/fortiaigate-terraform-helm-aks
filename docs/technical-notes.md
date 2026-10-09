# Terraform and Helm technical notes

Start with the [quickstart](../README.md#quickstart) and [deployment guide](deployment-guide.md). Use [operations](operations.md) for credential adoption and [teardown](teardown.md) for removal.

## Ownership and value precedence

- Preserve resource addresses for existing networks, storage, credentials, and generated TLS. Counted network resources use moved declarations to retain the original addresses. External VNets/subnets are read through data sources and remain externally owned.
- Terraform owns PostgreSQL passwords, Redis authentication, the encryption key, and CSRF key. Never generate new values against retained data. The chart receives existing Secret names; adopt live values before changing ownership.
- Helm values merge in this order: automatic GPU profile → `extra_values_files` → explicit `gpu_tuning` fields → app/GPU placement → application Secrets → database storage/authentication → private gateway → trusted root → ingress annotations → TLS. Later values win; Terraform `set` blocks have final precedence. Use structured YAML for lists and annotation keys containing dots/slashes.
- `deployment.chartRevision` hashes local chart content so Terraform notices template, values, file, and subchart changes. Workload rollouts depend on pod-spec changes and certificate/model checksums.
- Preserve generated web certificate resources and the CA. A separate internal leaf uses the effective `postgresql.auth.username` as its CN for database certificate authentication; its Secret name and CA remain stable. Web and internal leaf replacement have independent rollout checksums.
- Keep shared RWX data on Azure Files and each database on Azure Disk RWO storage. A successful Helm render does not qualify database migrations or storage changes.
- Keep `gpu_driver = "Install"`, app/GPU node selectors, and GPU taint tolerations. Deployment licensing does not require node-license affinity. Terraform keeps the unsupplied DP agent disabled; its optional chart path remains for compatibility.
- Use vendored subcharts. Do not refresh dependencies during an application build port; they contain deployment-license placement fixes.

## Terraform file map

| File | Responsibility |
| --- | --- |
| `network.tf` | Resource group, managed/external network selection, subnet validation and identity grants |
| `aks.tf` | AKS, app/GPU pools, driver configuration, ACR and AGIC grants |
| `appgw.tf` | Private Application Gateway, trusted root and AGIC ownership boundaries |
| `storage.tf` | Shared Azure Files account, identity grants and StorageClass |
| `helm.tf` | Application/device-plugin/Reloader releases, database credentials, mandatory Helm values |
| `gpu.tf` | Azure A10 profile and explicit inference tuning |
| `secrets.tf` | Stable encryption, CSRF and Redis credentials |
| `tls.tf` | Generated CA, independent web/internal leaves, supplied web certificate checks and Secrets |
| `certmanager.tf` | Azure DNS workload identity, cert-manager, issuer and web Certificate |
| `providers.tf` | Azure, Kubernetes and Helm authentication |
| `backend.tf` | Azure Storage backend declaration, configured at init |
| `outputs.tf` | Cluster access, ingress, storage and CA outputs |
