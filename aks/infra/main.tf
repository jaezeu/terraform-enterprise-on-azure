# =============================================================================
# Layer 1: AKS infrastructure — VNet, AKS cluster, PostgreSQL Flexible Server,
# Azure Cache for Redis, Storage Account, workload identity for external-dns.
# Applied first. The addons and tfe layers read outputs from this workspace
# via terraform_remote_state (enable remote state sharing on this workspace).
# =============================================================================

resource "azurerm_resource_group" "tfe" {
  name     = "${var.friendly_name_prefix}-tfe-aks-rg"
  location = var.location
  tags     = merge(var.tags, { managed_by = "terraform" })
}

# ---------------------------------------------------------------------------
# Networking — VNet + subnets for the TFE AKS deployment (10.0.0.0/16).
# Separate VNet from the VM deployment (10.1.0.0/16) so both coexist.
# ---------------------------------------------------------------------------
resource "azurerm_virtual_network" "tfe" {
  name                = "${var.friendly_name_prefix}-tfe-aks-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.tfe.location
  resource_group_name = azurerm_resource_group.tfe.name
  tags                = merge(var.tags, { managed_by = "terraform" })
}

resource "azurerm_subnet" "aks" {
  name                 = "aks"
  resource_group_name  = azurerm_resource_group.tfe.name
  virtual_network_name = azurerm_virtual_network.tfe.name
  address_prefixes     = ["10.0.1.0/24"]

  service_endpoints = ["Microsoft.Sql", "Microsoft.Storage"]
}

resource "azurerm_subnet" "db" {
  name                 = "db"
  resource_group_name  = azurerm_resource_group.tfe.name
  virtual_network_name = azurerm_virtual_network.tfe.name
  address_prefixes     = ["10.0.2.0/24"]

  delegation {
    name = "postgres"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "redis" {
  name                 = "redis"
  resource_group_name  = azurerm_resource_group.tfe.name
  virtual_network_name = azurerm_virtual_network.tfe.name
  address_prefixes     = ["10.0.3.0/24"]
}

# ---------------------------------------------------------------------------
# TFE AKS HVD module — creates AKS cluster, PostgreSQL Flexible Server,
# Azure Cache for Redis, and an Azure Storage Account.
# ---------------------------------------------------------------------------
module "tfe_aks" {
  source  = "hashicorp/terraform-enterprise-aks-hvd/azurerm"
  version = "0.2.0"

  # Naming & location
  friendly_name_prefix  = var.friendly_name_prefix
  location              = var.location
  resource_group_name   = azurerm_resource_group.tfe.name
  create_resource_group = false
  common_tags           = merge(var.tags, { managed_by = "terraform" })

  # DNS
  tfe_fqdn = var.tfe_fqdn

  # Networking
  vnet_id         = azurerm_virtual_network.tfe.id
  aks_subnet_id   = azurerm_subnet.aks.id
  db_subnet_id    = azurerm_subnet.db.id
  redis_subnet_id = azurerm_subnet.redis.id

  # Create a new AKS cluster (defaults to false in the module)
  create_aks_cluster       = true
  create_aks_tfe_node_pool = true
  aks_kubernetes_version   = var.aks_kubernetes_version

  # Leave empty only when using HCP Terraform hosted runners, whose execution
  # IPs are not published. Use an HCP Terraform Agent inside the VNet to make
  # an API allowlist practical.
  aks_api_server_authorized_ip_ranges = var.aks_api_server_authorized_ip_ranges

  # Enable OIDC + Workload Identity (required for external-dns Workload Identity)
  aks_oidc_issuer_enabled          = true
  aks_workload_identity_enabled    = true
  tfe_object_storage_azure_use_msi = true

  # Database password — name only; module fetches the value from Key Vault
  tfe_database_password_keyvault_id          = data.azurerm_key_vault.bootstrap.id
  tfe_database_password_keyvault_secret_name = data.azurerm_key_vault_secret.db_password.name

  # Helm overrides file: the tfe layer manages Helm instead
  create_helm_overrides_file = false

}

# ---------------------------------------------------------------------------
# User-assigned managed identity for external-dns (Azure Workload Identity).
# The HVD module creates a TFE identity; this is a separate one for external-dns
# so that DNS zone access is isolated.
# ---------------------------------------------------------------------------
resource "azurerm_user_assigned_identity" "external_dns" {
  name                = "${var.friendly_name_prefix}-external-dns-id"
  resource_group_name = azurerm_resource_group.tfe.name
  location            = azurerm_resource_group.tfe.location
  tags                = merge(var.tags, { managed_by = "terraform" })
}

# DNS Zone Contributor role so external-dns can create/update A records.
resource "azurerm_role_assignment" "external_dns_dns_contributor" {
  scope                = data.azurerm_dns_zone.tfe.id
  role_definition_name = "DNS Zone Contributor"
  principal_id         = azurerm_user_assigned_identity.external_dns.principal_id
}

resource "azurerm_role_assignment" "external_dns_resource_group_reader" {
  scope                = data.azurerm_resource_group.dns_zone.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.external_dns.principal_id
}

# Federated identity credential — binds the managed identity to the
# external-dns Kubernetes service account via the AKS OIDC issuer.
# Subject follows Kubernetes workload identity format (not HCP Terraform
# format — this is a K8s service account binding, not a Terraform run).
locals {
  external_dns_namespace   = "external-dns"
  external_dns_svc_account = "external-dns"
}

resource "azurerm_federated_identity_credential" "external_dns" {
  name                = "${var.friendly_name_prefix}-external-dns"
  resource_group_name = azurerm_resource_group.tfe.name
  parent_id           = azurerm_user_assigned_identity.external_dns.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = data.azurerm_kubernetes_cluster.tfe.oidc_issuer_url
  subject             = "system:serviceaccount:${local.external_dns_namespace}:${local.external_dns_svc_account}"
}
