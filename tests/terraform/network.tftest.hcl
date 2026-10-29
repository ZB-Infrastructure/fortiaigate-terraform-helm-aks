# All providers are mocked: these tests never access Azure or Kubernetes.
mock_provider "azurerm" {
  mock_resource "azurerm_resource_group" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test"
    }
  }
  mock_resource "azurerm_virtual_network" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test/providers/Microsoft.Network/virtualNetworks/test"
    }
  }
  mock_resource "azurerm_subnet" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test/providers/Microsoft.Network/virtualNetworks/test/subnets/test"
    }
  }
  mock_resource "azurerm_public_ip" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test/providers/Microsoft.Network/publicIPAddresses/test"
    }
  }
  mock_resource "azurerm_application_gateway" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test/providers/Microsoft.Network/applicationGateways/test"
    }
  }
  mock_resource "azurerm_storage_account" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test/providers/Microsoft.Storage/storageAccounts/test"
    }
  }
  mock_resource "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/test"
      client_id    = "11111111-1111-1111-1111-111111111111"
      principal_id = "22222222-2222-2222-2222-222222222222"
    }
  }
  mock_resource "azurerm_kubernetes_cluster" {
    defaults = {
      id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test/providers/Microsoft.ContainerService/managedClusters/test"
      identity = { principal_id = "33333333-3333-3333-3333-333333333333" }
      ingress_application_gateway = {
        ingress_application_gateway_identity = [{
          object_id                 = "44444444-4444-4444-4444-444444444444"
          client_id                 = "55555555-5555-5555-5555-555555555555"
          user_assigned_identity_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/agic"
        }]
      }
    }
  }
  mock_data "azurerm_virtual_network" {
    defaults = {
      id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network/providers/Microsoft.Network/virtualNetworks/shared"
      name                = "shared"
      resource_group_name = "network"
      location            = "eastus"
    }
  }
  mock_data "azurerm_subnet" {
    defaults = { address_prefixes = ["10.20.4.0/24"] }
  }
  mock_data "azurerm_dns_zone" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test/providers/Microsoft.Network/dnsZones/example.com" }
  }
  mock_data "azurerm_client_config" {
    defaults = {
      subscription_id = "00000000-0000-0000-0000-000000000000"
      tenant_id       = "00000000-0000-0000-0000-000000000000"
    }
  }
}
mock_provider "azuread" {}
mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "random" {}
mock_provider "tls" {}

variables {
  image_repository = "registry.example/fortiaigate"
  gpu_enabled      = false
  ingress_host     = "fortiaigate.example.com"
}
run "managed_network" {
  command = apply
  assert {
    condition     = azurerm_role_assignment.cluster_storage_contributor.principal_id == azurerm_kubernetes_cluster.this.identity[0].principal_id
    error_message = "Managed networking must grant storage provisioning access to the system-assigned cluster identity."
  }
  assert {
    condition     = length(azurerm_virtual_network.this) == 1 && length(azurerm_subnet.aks) == 1 && length(azurerm_subnet.appgw) == 1 && length(azurerm_user_assigned_identity.aks_network) == 0
    error_message = "Default networking must remain managed without a new cluster identity."
  }
}
run "existing_public" {
  command = apply
  assert {
    condition     = azurerm_role_assignment.cluster_storage_contributor.principal_id == azurerm_user_assigned_identity.aks_network[0].principal_id
    error_message = "Existing networking must grant storage provisioning access to the user-assigned control-plane identity."
  }
  variables {
    existing_vnet_id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network/providers/Microsoft.Network/virtualNetworks/shared"
    existing_aks_subnet_id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network/providers/Microsoft.Network/virtualNetworks/shared/subnets/aks"
    existing_appgw_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network/providers/Microsoft.Network/virtualNetworks/shared/subnets/gateway"
    internal                 = false
    agic_enabled             = true
    ingress_class            = "azure-application-gateway"
    gpu_enabled              = true
    service_cidr             = "172.20.0.0/16"
    dns_service_ip           = "172.20.0.10"
  }
  assert {
    condition     = length(azurerm_virtual_network.this) == 0 && length(azurerm_subnet.aks) == 0 && length(azurerm_subnet.appgw) == 0
    error_message = "Existing network mode must not manage the VNet or subnets."
  }
  assert {
    condition     = azurerm_kubernetes_cluster.this.default_node_pool[0].vnet_subnet_id == var.existing_aks_subnet_id && azurerm_kubernetes_cluster_node_pool.gpu[0].vnet_subnet_id == var.existing_aks_subnet_id && azurerm_role_assignment.aks_subnet_network_contributor[0].scope == var.existing_aks_subnet_id
    error_message = "Both node pools and the identity grant must use the supplied AKS subnet."
  }
  assert {
    condition     = azurerm_kubernetes_cluster.this.network_profile[0].service_cidr == "172.20.0.0/16" && azurerm_kubernetes_cluster.this.network_profile[0].dns_service_ip == "172.20.0.10"
    error_message = "Service networking overrides must reach AKS."
  }
  assert {
    condition     = azurerm_role_assignment.agic_appgw_subnet_network_contributor[0].scope == var.existing_appgw_subnet_id
    error_message = "AGIC must receive permission on the supplied gateway subnet."
  }
}
run "existing_private" {
  command = apply
  assert {
    condition     = azurerm_role_assignment.cluster_storage_contributor.principal_id == azurerm_user_assigned_identity.aks_network[0].principal_id
    error_message = "Existing networking must grant storage provisioning access to the user-assigned control-plane identity."
  }
  variables {
    existing_vnet_id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network/providers/Microsoft.Network/virtualNetworks/shared"
    existing_aks_subnet_id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network/providers/Microsoft.Network/virtualNetworks/shared/subnets/aks"
    existing_appgw_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network/providers/Microsoft.Network/virtualNetworks/shared/subnets/gateway"
    internal                 = true
    agic_enabled             = true
    ingress_class            = "azure-application-gateway"
    gpu_enabled              = true
    service_cidr             = "172.20.0.0/16"
    dns_service_ip           = "172.20.0.10"
  }
  assert {
    condition     = length(azurerm_virtual_network.this) == 0 && length(azurerm_subnet.aks) == 0 && length(azurerm_subnet.appgw) == 0
    error_message = "Existing network mode must not manage the VNet or subnets."
  }
  assert {
    condition     = azurerm_kubernetes_cluster.this.default_node_pool[0].vnet_subnet_id == var.existing_aks_subnet_id && azurerm_kubernetes_cluster_node_pool.gpu[0].vnet_subnet_id == var.existing_aks_subnet_id && azurerm_role_assignment.aks_subnet_network_contributor[0].scope == var.existing_aks_subnet_id
    error_message = "Both node pools and the identity grant must use the supplied AKS subnet."
  }
  assert {
    condition     = azurerm_kubernetes_cluster.this.network_profile[0].service_cidr == "172.20.0.0/16" && azurerm_kubernetes_cluster.this.network_profile[0].dns_service_ip == "172.20.0.10"
    error_message = "Service networking overrides must reach AKS."
  }
  assert {
    condition     = azurerm_role_assignment.agic_appgw_subnet_network_contributor[0].scope == var.existing_appgw_subnet_id
    error_message = "AGIC must receive permission on the supplied gateway subnet."
  }
  assert {
    condition     = local.appgw_private_ip == "10.20.4.254" && azurerm_application_gateway.this[0].gateway_ip_configuration[0].subnet_id == var.existing_appgw_subnet_id
    error_message = "Private gateway must use the actual external subnet prefix and ID."
  }
}
run "existing_without_agic" {
  command = apply
  assert {
    condition     = azurerm_role_assignment.cluster_storage_contributor.principal_id == azurerm_user_assigned_identity.aks_network[0].principal_id
    error_message = "Existing networking must grant storage provisioning access to the user-assigned control-plane identity."
  }
  variables {
    existing_vnet_id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network/providers/Microsoft.Network/virtualNetworks/shared"
    existing_aks_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network/providers/Microsoft.Network/virtualNetworks/shared/subnets/aks"
    internal               = false
    agic_enabled           = false
    ingress_class          = "nginx"
    gpu_enabled            = true
    service_cidr           = "172.20.0.0/16"
    dns_service_ip         = "172.20.0.10"
  }
  assert {
    condition     = length(azurerm_virtual_network.this) == 0 && length(azurerm_subnet.aks) == 0 && length(azurerm_subnet.appgw) == 0
    error_message = "Existing network mode must not manage the VNet or subnets."
  }
  assert {
    condition     = azurerm_kubernetes_cluster.this.default_node_pool[0].vnet_subnet_id == var.existing_aks_subnet_id && azurerm_kubernetes_cluster_node_pool.gpu[0].vnet_subnet_id == var.existing_aks_subnet_id && azurerm_role_assignment.aks_subnet_network_contributor[0].scope == var.existing_aks_subnet_id
    error_message = "Both node pools and the identity grant must use the supplied AKS subnet."
  }
  assert {
    condition     = azurerm_kubernetes_cluster.this.network_profile[0].service_cidr == "172.20.0.0/16" && azurerm_kubernetes_cluster.this.network_profile[0].dns_service_ip == "172.20.0.10"
    error_message = "Service networking overrides must reach AKS."
  }
}
run "missing_vnet" {
  command = plan
  variables {
    existing_aks_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network/providers/Microsoft.Network/virtualNetworks/shared/subnets/aks"
  }
  expect_failures = [terraform_data.network_configuration]
}
run "missing_gateway" {
  command = plan
  variables {
    existing_vnet_id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network/providers/Microsoft.Network/virtualNetworks/shared"
    existing_aks_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network/providers/Microsoft.Network/virtualNetworks/shared/subnets/aks"
  }
  expect_failures = [terraform_data.network_configuration]
}
run "wrong_vnet" {
  command = plan
  variables {
    existing_vnet_id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network/providers/Microsoft.Network/virtualNetworks/shared"
    existing_aks_subnet_id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network/providers/Microsoft.Network/virtualNetworks/sharedother/subnets/aks"
    existing_appgw_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network/providers/Microsoft.Network/virtualNetworks/shared/subnets/gateway"
  }
  expect_failures = [terraform_data.network_configuration]
}
run "shared_subnet" {
  command = plan
  variables {
    existing_vnet_id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network/providers/Microsoft.Network/virtualNetworks/shared"
    existing_aks_subnet_id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network/providers/Microsoft.Network/virtualNetworks/shared/subnets/aks"
    existing_appgw_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network/providers/Microsoft.Network/virtualNetworks/shared/subnets/aks"
  }
  expect_failures = [terraform_data.network_configuration]
}
