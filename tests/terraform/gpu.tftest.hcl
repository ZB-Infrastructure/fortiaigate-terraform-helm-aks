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
        effective_gateway_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/MC_test/providers/Microsoft.Network/applicationGateways/addon-gateway"
        ingress_application_gateway_identity = [{
          object_id                 = "44444444-4444-4444-4444-444444444444"
          client_id                 = "55555555-5555-5555-5555-555555555555"
          user_assigned_identity_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/agic"
        }]
      }
    }
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
mock_provider "azapi" {}
mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "random" {}
mock_provider "tls" {}

variables {
  image_repository = "example.com/fortiaigate"
}

run "a10_auto" {
  command = plan
  variables {
    gpu_enabled      = true
    gpu_node_vm_size = "Standard_NV36ads_A10_v5"
  }
  assert {
    condition     = local.gpu_profile == "a10" && yamldecode(local.gpu_profile_values[0]).triton.resources.requests.memory == "12Gi" && yamldecode(local.gpu_profile_values[0]).triton.resources.limits.memory == "25Gi" && yamldecode(local.gpu_profile_values[0]).vllm.resources.requests.memory == "8Gi" && length(local.gpu_tuning_values) == 0
    error_message = "A10 must fit its memory requests without capping Triton at the failed 6Gi limit."
  }
}

run "a100_preserves_chart" {
  command = plan
  variables {
    gpu_enabled      = true
    gpu_node_vm_size = "Standard_NC24ads_A100_v4"
  }
  assert {
    condition     = local.gpu_profile == "chart" && length(local.gpu_helm_values) == 0
    error_message = "Non-A10 auto tuning must preserve chart defaults."
  }
}

run "cpu_has_no_gpu_overrides" {
  command = plan
  variables {
    gpu_enabled      = false
    gpu_node_vm_size = "Standard_NV36ads_A10_v5"
    gpu_tuning       = { vllm_max_num_seqs = 16 }
  }
  assert {
    condition     = length(local.gpu_profile_values) == 0 && length(local.gpu_tuning_values) == 0
    error_message = "CPU deployments must omit inference profiles and tuning."
  }
}

run "explicit_tuning_wins" {
  command = plan
  variables {
    gpu_enabled        = true
    gpu_node_vm_size   = "Standard_NV36ads_A10_v5"
    extra_values_files = ["tests/terraform/gpu-overlay.yaml"]
    gpu_tuning         = { vllm_max_num_seqs = 16, triton_memory_limit = "26Gi" }
  }
  assert {
    condition     = length(local.gpu_helm_values) == 3 && yamldecode(local.gpu_helm_values[1]).vllm.maxNumSeqs == 48 && yamldecode(local.gpu_helm_values[2]).vllm.maxNumSeqs == 16 && yamldecode(local.gpu_helm_values[2]).triton.resources.limits.memory == "26Gi" && !contains(keys(yamldecode(local.gpu_helm_values[2]).vllm), "maxModelLen")
    error_message = "Explicit tfvars fields must follow advanced files and leave unset chart knobs alone."
  }
}

run "disable_profile" {
  command = plan
  variables {
    gpu_enabled        = true
    gpu_node_vm_size   = "Standard_NV36ads_A10_v5"
    gpu_tuning_profile = "chart"
  }
  assert {
    condition     = length(local.gpu_profile_values) == 0
    error_message = "The chart profile must disable automatic A10 defaults."
  }
}

run "reject_unknown_profile" {
  command = plan
  variables { gpu_tuning_profile = "unknown" }
  expect_failures = [var.gpu_tuning_profile]
}

run "reject_invalid_memory" {
  command = plan
  variables { gpu_tuning = { triton_memory_limit = "0Gi" } }
  expect_failures = [var.gpu_tuning]
}

run "reject_fractional_count" {
  command = plan
  variables { gpu_tuning = { vllm_max_num_seqs = 1.5 } }
  expect_failures = [var.gpu_tuning]
}

run "reject_gpu_budget" {
  command = plan
  variables { gpu_tuning = { vllm_gpu_memory_utilization = 1 } }
  expect_failures = [var.gpu_tuning]
}

run "reject_request_above_limit" {
  command = plan
  variables { gpu_tuning = { triton_memory_request = "12Gi", triton_memory_limit = "1024Mi" } }
  expect_failures = [var.gpu_tuning]
}
