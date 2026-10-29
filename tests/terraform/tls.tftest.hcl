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
  image_repository = "registry.example/fortiaigate"
  gpu_enabled      = false
  ingress_host     = "fortiaigate.example.com"
}

run "generated" {
  command = apply
  assert {
    condition     = length(azurerm_application_gateway.this) == 0 && length(azurerm_public_ip.appgw) == 0 && length(azapi_update_resource.public_appgw_trusted_root) == 1
    error_message = "Default public mode must configure trust on the existing add-on gateway without creating a replacement gateway or public IP."
  }
  assert {
    condition     = azapi_update_resource.public_appgw_trusted_root[0].resource_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/MC_test/providers/Microsoft.Network/applicationGateways/addon-gateway"
    error_message = "The root upload must target the gateway ID returned by AKS, not an assumed resource group or name."
  }
  assert {
    condition = azapi_update_resource.public_appgw_trusted_root[0].body == {
      properties = {
        trustedRootCertificates = [{
          name       = "fortiaigate-ca"
          properties = { data = base64encode(tls_self_signed_cert.ca[0].cert_pem) }
        }]
      }
    }
    error_message = "Public gateway updates must contain only the named generated trust root, with no routing or frontend changes."
  }
  assert {
    condition     = azapi_update_resource.public_appgw_trusted_root[0].list_unique_id_property["properties.trustedRootCertificates"] == "name" && contains(azapi_update_resource.public_appgw_trusted_root[0].ignore_other_items_in_list, "properties.trustedRootCertificates")
    error_message = "Root updates must merge by name and ignore unrelated root certificates during drift checks."
  }
  assert {
    condition     = yamldecode(local.appgw_trusted_root_values[0]).ingress.annotations["appgw.ingress.kubernetes.io/appgw-trusted-root-certificate"] == "fortiaigate-ca"
    error_message = "Public ingress must select the uploaded trust root."
  }
  assert {
    condition     = local.generated_web_tls && local.web_has_private_ca
    error_message = "Default web TLS must use the generated CA."
  }
  assert {
    condition     = yamldecode(local.tls_values[0]).postgresql.tls.enabled && yamldecode(local.tls_values[0]).redis.tls.enabled
    error_message = "Generated mode must enable database TLS."
  }
  assert {
    condition     = yamldecode(local.application_secret_values[0]).api.masterKeyExistingSecret == "fortiaigate-application" && yamldecode(local.application_secret_values[0]).redis.auth.existingSecret == "fortiaigate-redis"
    error_message = "Application encryption/CSRF and Redis credentials must reference Terraform-owned secrets."
  }
  assert {
    condition     = contains(tls_cert_request.fortiaigate[0].dns_names, "guardrail.fortiaigate.svc.cluster.local") && contains(tls_cert_request.fortiaigate[0].dns_names, "llm-gateway")
    error_message = "Generated certificates must cover the new service names."
  }
}

run "supplied_public" {
  command = apply
  variables {
    tls_certificate_path = "test-cert.pem"
    tls_private_key_path = "test-key.pem"
  }
  assert {
    condition     = length(azapi_update_resource.public_appgw_trusted_root) == 0 && length(local.appgw_trusted_root_values) == 0
    error_message = "Publicly trusted supplied certificates must use the gateway's built-in CA store without a private-root annotation."
  }
  assert {
    condition     = local.supplied_tls && !local.web_has_private_ca && local.web_trusted_root == ""
    error_message = "Public supplied certificates must not upload the internal CA to the gateway."
  }
  assert {
    condition     = nonsensitive(kubernetes_secret.tls[0].data["tls.crt"]) == file("test-cert.pem")
    error_message = "The web secret must contain the supplied chain."
  }
  assert {
    condition     = nonsensitive(kubernetes_secret.tls[0].data["tls.key"]) == file("test-key.pem")
    error_message = "The web secret must contain the supplied key."
  }
  assert {
    condition     = yamldecode(local.tls_values[0]).tls.internalExistingSecret == "fortiaigate-internal-tls-secret" && yamldecode(local.tls_values[0]).redis.tls.certCAFilename == "ca.crt"
    error_message = "Database clients must use a separate internal secret and CA."
  }
  assert {
    condition     = yamldecode(local.ingress_annotation_values[0]).ingress.annotations["appgw.ingress.kubernetes.io/health-probe-hostname"] == var.ingress_host
    error_message = "Gateway probes must validate the supplied certificate's ingress hostname."
  }
  assert {
    condition     = nonsensitive(kubernetes_secret.internal_tls.data["ca.crt"]) == run.generated.internal_tls_ca_certificate
    error_message = "Changing web certificate source must preserve the internal CA."
  }
  assert {
    condition     = yamldecode(local.tls_values[0]).postgresql.primary.podAnnotations["checksum/tls"] == local.internal_tls_checksum && yamldecode(local.tls_values[0]).redis.master.podAnnotations["checksum/tls"] == local.internal_tls_checksum
    error_message = "Database rollout checksums must depend on internal certificates."
  }
}

run "supplied_private" {
  command = apply
  variables {
    internal                = true
    tls_certificate_path    = "test-cert.pem"
    tls_private_key_path    = "test-key.pem"
    tls_ca_certificate_path = "test-cert.pem"
  }
  assert {
    condition     = local.web_trusted_root == file("test-cert.pem") && length(azurerm_application_gateway.this[0].trusted_root_certificate) == 1
    error_message = "A supplied private CA must be installed on the private gateway."
  }
  assert {
    condition     = one(azurerm_application_gateway.this[0].trusted_root_certificate).data == base64encode(file("test-cert.pem"))
    error_message = "The gateway must trust the supplied CA, not the internal CA."
  }
  assert {
    condition     = length(azapi_update_resource.public_appgw_trusted_root) == 0 && yamldecode(local.appgw_trusted_root_values[0]).ingress.annotations["appgw.ingress.kubernetes.io/appgw-trusted-root-certificate"] == "fortiaigate-ca"
    error_message = "Private gateways must retain AzureRM certificate ownership and the trust annotation."
  }
}

run "supplied_private_public_gateway" {
  command = apply
  variables {
    tls_certificate_path    = "test-cert.pem"
    tls_private_key_path    = "test-key.pem"
    tls_ca_certificate_path = "test-cert.pem"
  }
  assert {
    condition     = azapi_update_resource.public_appgw_trusted_root[0].body.properties.trustedRootCertificates[0].properties.data == base64encode(file("test-cert.pem"))
    error_message = "Public gateways must upload the supplied private root rather than the generated internal CA."
  }
  assert {
    condition     = yamldecode(local.appgw_trusted_root_values[0]).ingress.annotations["appgw.ingress.kubernetes.io/appgw-trusted-root-certificate"] == "fortiaigate-ca"
    error_message = "Supplied private roots must be selected by public ingress."
  }
}

run "generated_private_gateway" {
  command = apply
  variables {
    internal = true
  }
  assert {
    condition     = length(azapi_update_resource.public_appgw_trusted_root) == 0 && one(azurerm_application_gateway.this[0].trusted_root_certificate).data == base64encode(tls_self_signed_cert.ca[0].cert_pem)
    error_message = "Generated private gateway trust must stay in the existing AzureRM resource."
  }
}

run "letsencrypt" {
  command = apply
  variables {
    letsencrypt_enabled     = true
    acme_email              = "operator@example.com"
    dns_zone_name           = "example.com"
    dns_zone_resource_group = "dns-test"
  }
  assert {
    condition     = length(azapi_update_resource.public_appgw_trusted_root) == 0 && length(local.appgw_trusted_root_values) == 0
    error_message = "Let's Encrypt must not upload or select the generated internal CA for web backends."
  }
  assert {
    condition     = length(kubernetes_secret.tls) == 0 && local.web_trusted_root == ""
    error_message = "Cert-manager must own web TLS in Let's Encrypt mode."
  }
  assert {
    condition     = yamldecode(local.tls_values[0]).postgresql.tls.enabled && yamldecode(local.tls_values[0]).redis.tls.enabled && length(tls_self_signed_cert.ca) == 1
    error_message = "Let's Encrypt must preserve internal CA and database TLS."
  }
  assert {
    condition     = tls_self_signed_cert.ca[0].cert_pem == run.generated.internal_tls_ca_certificate
    error_message = "Enabling Let's Encrypt must preserve the internal CA."
  }
}

run "missing_key" {
  command = plan
  variables {
    tls_certificate_path = "test-cert.pem"
  }
  expect_failures = [terraform_data.tls_configuration]
}

run "missing_certificate" {
  command = plan
  variables {
    tls_private_key_path = "test-key.pem"
  }
  expect_failures = [terraform_data.tls_configuration]
}

run "conflicting_modes" {
  command = plan
  variables {
    tls_certificate_path    = "test-cert.pem"
    tls_private_key_path    = "test-key.pem"
    letsencrypt_enabled     = true
    acme_email              = "operator@example.com"
    dns_zone_name           = "example.com"
    dns_zone_resource_group = "dns-test"
  }
  expect_failures = [terraform_data.tls_configuration]
}

run "missing_hostname" {
  command = plan
  variables {
    tls_certificate_path = "test-cert.pem"
    tls_private_key_path = "test-key.pem"
    ingress_host         = ""
  }
  expect_failures = [terraform_data.tls_configuration]
}

run "orphan_ca" {
  command = plan
  variables {
    tls_ca_certificate_path = "test-cert.pem"
  }
  expect_failures = [terraform_data.tls_configuration]
}

run "unreadable_certificate" {
  command = plan
  variables {
    tls_certificate_path = "missing.pem"
    tls_private_key_path = "test-key.pem"
  }
  expect_failures = [var.tls_certificate_path]
}

run "build0055_shared_gpu" {
  command = apply
  variables {
    gpu_enabled    = true
    gpu_node_count = 1
  }
  assert {
    condition     = helm_release.fortiaigate.version == "8.0.2" && var.image_tag == "V8.0.2-build0055"
    error_message = "Fresh installations must use the build0055 chart/image set."
  }
  assert {
    condition     = azurerm_kubernetes_cluster_node_pool.gpu[0].min_count == 1 && azurerm_kubernetes_cluster_node_pool.gpu[0].gpu_driver == "Install"
    error_message = "GPU capacity and explicit AKS driver configuration must be preserved."
  }
  assert {
    condition     = one([for item in helm_release.fortiaigate.set : item.value if item.name == "vllm.gpuAttach"]) == "shared" && one([for item in helm_release.fortiaigate.set : item.value if item.name == "dpAgent.enabled"]) == "false"
    error_message = "Shared GPU must be explicit and the unsupplied DP agent must stay disabled."
  }
  assert {
    condition     = yamldecode(local.placement_values[0]).fortiaigate.gpuWorkloadPlacement.nodeSelector["fortiaigate-role"] == "gpu" && yamldecode(local.placement_values[0]).postgresql.primary.nodeSelector["fortiaigate-role"] == "app"
    error_message = "Terraform must pass GPU and database placement into the release values."
  }
}

run "build0055_dedicated_gpu" {
  command = apply
  variables {
    gpu_enabled     = true
    gpu_node_count  = 2
    vllm_gpu_attach = "dedicated"
  }
  assert {
    condition     = azurerm_kubernetes_cluster_node_pool.gpu[0].min_count == 2 && azurerm_kubernetes_cluster_node_pool.gpu[0].max_count == 2 && one([for item in helm_release.fortiaigate.set : item.value if item.name == "vllm.gpuAttach"]) == "dedicated"
    error_message = "Dedicated mode must configure the requested GPU pool capacity and chart topology."
  }
}

run "obsolete_node_license" {
  command = plan
  variables {
    licenses = { "aks-app-old-node" = "missing-license.lic" }
  }
  expect_failures = [var.licenses]
}

run "invalid_gpu_count" {
  command = plan
  variables {
    gpu_node_count = 0
  }
  expect_failures = [var.gpu_node_count]
}

run "invalid_gpu_topology" {
  command = plan
  variables {
    vllm_gpu_attach = "auto"
  }
  expect_failures = [var.vllm_gpu_attach]
}

run "internal_certificate_identity" {
  command = apply
  assert {
    condition     = tls_cert_request.internal.subject[0].common_name == "fortiaigate_postgres_user" && tls_cert_request.fortiaigate[0].subject[0].common_name == var.ingress_host && tls_cert_request.internal.dns_names == tls_cert_request.fortiaigate[0].dns_names
    error_message = "Internal certificate CN must match PostgreSQL without changing web identity or service SANs."
  }
}

run "internal_certificate_overlay_identity" {
  command = apply
  variables {
    extra_values_files = ["tests/terraform/postgres-user.yaml", "tests/terraform/postgres-user-final.yaml"]
  }
  assert {
    condition     = tls_cert_request.internal.subject[0].common_name == "final_user"
    error_message = "Internal client certificate must follow final Helm username precedence."
  }
}
