# Staged teardown

Return to the [quickstart](../README.md#quickstart). Use the same subscription, backend, tfvars, supplied PEM files, and Helm overlay files as deployment.

**Full destruction deletes the Terraform-owned Azure Files storage account and its shares.** Namespace deletion removes Secrets and PVCs; Azure Disk volumes can be deleted according to their PV reclaim policies. `Retain` on the shared Azure Files StorageClass only protects the PV/share from PVC reclamation, not from storage account or resource group destruction.

Before proceeding, back up PostgreSQL and Redis, shared files, application Secrets (especially the master encryption key), database credentials, Helm values, and Terraform state to a secure location outside the deployment resource group. Test restoration if the data must remain usable. Do not proceed with full destruction if the existing storage must survive; arrange separate storage ownership first.

```bash
FAIG_BACKEND="backends/dev.hcl"
FAIG_VARS="tfvars/dev.tfvars"
FAIG_NAMESPACE="fortiaigate" # match namespace in tfvars
az account show --query '{subscription:id,name:name}' -o table
terraform init -backend-config="$FAIG_BACKEND" -reconfigure
$(terraform output -raw configure_kubectl)
kubectl get nodes
terraform output resource_group_name
terraform output storage_account_name
kubectl get pvc -n "$FAIG_NAMESPACE"
kubectl get pv

# Stage 1: remove the application while AKS, AGIC and storage drivers are running.
terraform destroy -target=helm_release.fortiaigate -var-file="$FAIG_VARS"
kubectl get ingress,pods,pvc -n "$FAIG_NAMESPACE"
```

Wait for application pods and Ingress cleanup. Confirm Application Gateway no longer has the application's listener/routing bindings before removing AKS. AGIC is an AKS add-on and must remain available during this cleanup. Investigate stuck finalizers using Ingress events and controller logs; do not strip finalizers to bypass cleanup. Database PVCs may remain after Helm uninstall, so inventory them and confirm backups before namespace deletion.

```bash
# Stage 2: remove remaining Terraform-managed cluster resources while AKS exists.
# Optional release targets resolve to no instances when disabled.
terraform destroy \
  -target=helm_release.nvidia_device_plugin \
  -target=helm_release.reloader \
  -target=helm_release.cert_manager_issuer \
  -target=helm_release.cert_manager \
  -target=kubernetes_storage_class.azurefile \
  -target=kubernetes_namespace.fortiaigate \
  -var-file="$FAIG_VARS"

# Stage 3: review and destroy the remaining managed infrastructure.
terraform plan -destroy -var-file="$FAIG_VARS"
terraform destroy -var-file="$FAIG_VARS"
terraform state list
```

Review every destroy plan. AKS, nodes, networking, and the Azure Files account must remain until stage 3. Namespace deletion also removes manually created objects in that namespace. Stop on failures; do not run `terraform apply` between teardown stages because it recreates removed resources. Targeted Terraform destruction keeps release ownership recorded in state without a separate manual Helm uninstall.

Verify removal of the deployment resource group and inspect the AKS managed resource group for remaining disks, gateway resources, and retained storage. Record any intentionally retained volumes and their backup/cleanup ownership. External VNets/subnets remain when configured through existing IDs, provided they are outside the destroyed resource group. The separately bootstrapped state account, registry, external DNS zone/records, and externally owned resources remain; remove stale DNS records separately. Keep backups and the state backend until cleanup is verified.

This sequence requires live qualification; offline tests do not prove controller cleanup or data recovery. Record results in [testing](testing.md).
