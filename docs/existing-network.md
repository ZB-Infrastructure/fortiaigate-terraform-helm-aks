# Existing VNet and subnets

Use this mode for networking owned by another team or Terraform stack. The
VNet and subnets are read through data sources, never imported, modified, or
removed by this deployment. The deployment resource group remains owned by
this stack; keep the network in a separate resource group so destroying the
application cannot delete the network with it.

## Configure

Set these inputs in your ignored tfvars file:

```hcl
existing_vnet_id         = "/subscriptions/<subscription-id>/resourceGroups/<network-rg>/providers/Microsoft.Network/virtualNetworks/<vnet>"
existing_aks_subnet_id   = "/subscriptions/<subscription-id>/resourceGroups/<network-rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<aks-subnet>"
existing_appgw_subnet_id = "/subscriptions/<subscription-id>/resourceGroups/<network-rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<appgw-subnet>"

# Change together if the default service range conflicts with your networks.
service_cidr   = "10.1.0.0/16"
dns_service_ip = "10.1.0.10"
```

Supply the VNet and AKS subnet together. The Application Gateway subnet is
required when `agic_enabled = true`; omit it when AGIC is disabled. Both
subnets must belong to the supplied VNet. This mode currently supports the
same subscription as the AzureRM provider and the same region as AKS.
Application and GPU node pools share the supplied AKS subnet.

The managed `vnet_cidr`, `aks_subnet_cidr`, and `appgw_subnet_cidr` inputs do
not configure existing networking. For internal ingress, the default private
frontend IP is calculated from the existing gateway subnet's first address
prefix. Set `appgw_private_ip` explicitly if that address is occupied.

With all existing IDs unset, the stack creates networking as before. Moved
blocks preserve the state of existing managed networks when resources gain
conditional counts. Review the plan before applying. Switching an established
cluster between network modes is a migration: it can replace AKS and destroy
previously managed networking. Do not toggle the mode as a way to transfer
ownership of a live network.

## Permissions and prerequisites

The Terraform identity needs read access to the VNet/subnets, subnet join
permissions for gateway deployment, and role-assignment write access on both
subnets, in addition to normal deployment permissions. Rights scoped only to
the application's resource group do not cover a separate network resource group.

In existing-network mode Terraform creates a user-assigned AKS control-plane
identity in the deployment resource group and grants it Network Contributor on
the AKS subnet before cluster creation. AGIC receives Network Contributor on
its gateway subnet after its addon identity exists. Default managed-network
mode retains its system-assigned AKS identity. See Microsoft's
[managed identity guidance](https://learn.microsoft.com/en-us/azure/aks/use-managed-identity).
Azure RBAC propagation can delay access even after a role assignment completes;
if creation fails with a permission error, confirm the grants and retry after
propagation.

Before deploying, have the network owner verify:

- The gateway subnet is dedicated to Application Gateway, distinct from AKS,
  and has enough free addresses for gateway instances and a private frontend.
- The AKS subnet has capacity for nodes, Azure CNI pod addresses, and upgrades,
  including GPU nodes when enabled.
- The Kubernetes service CIDR does not overlap the VNet, peered networks, or
  on-premises networks, and `dns_service_ip` is a valid address in that range.
- NSGs, routes, firewalls, and DNS allow required AKS, gateway, registry,
  storage, and model-service traffic. This option does not change those controls.

See [Application Gateway infrastructure requirements](https://learn.microsoft.com/en-us/azure/application-gateway/configuration-infrastructure)
and [Azure CNI IP planning](https://learn.microsoft.com/en-us/azure/aks/configure-azure-cni).

## Deploy

Initialize the backend and use the README's two-step bootstrap. Its existing
network resource targets resolve to zero managed resources in this mode; the
AKS target pulls in the new identity and subnet grant automatically. Keep the
AGIC subnet grant in bootstrap so it is ready before the application install.
The full apply and this branch's license onboarding procedure remain as
specified in the [README](../README.md).

On teardown, Terraform removes its network role assignments and control-plane
identity while leaving the external VNet, subnets, NSGs, and routes intact.
An existing VNet does not by itself make AKS or application ingress private;
configure ingress separately using [the gateway guide](application-gateway-dns-tls.md).
