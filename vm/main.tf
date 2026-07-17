# =============================================================================
# Layer: VM — VNet + TFE HVD module (single apply).
# All networking (VNet, subnets) is managed here alongside the HVD module so
# the entire deployment is a single apply, mirroring the EC2 layout in the
# reference AWS repo.
# =============================================================================

resource "azurerm_resource_group" "tfe" {
  name     = "${var.friendly_name_prefix}-tfe-vm-rg"
  location = var.location
  tags     = merge(var.tags, { managed_by = "terraform" })
}

# ---------------------------------------------------------------------------
# Networking — VNet + subnets for the TFE VM deployment (10.1.0.0/16).
# Separate VNet from the AKS deployment (10.0.0.0/16) so both can coexist
# in the same subscription without address-space conflicts.
# ---------------------------------------------------------------------------
resource "azurerm_virtual_network" "tfe" {
  name                = "${var.friendly_name_prefix}-tfe-vnet"
  address_space       = ["10.1.0.0/16"]
  location            = azurerm_resource_group.tfe.location
  resource_group_name = azurerm_resource_group.tfe.name
  tags                = merge(var.tags, { managed_by = "terraform" })
}

resource "azurerm_subnet" "vm" {
  name                 = "vm"
  resource_group_name  = azurerm_resource_group.tfe.name
  virtual_network_name = azurerm_virtual_network.tfe.name
  address_prefixes     = ["10.1.1.0/24"]

  service_endpoints = ["Microsoft.KeyVault", "Microsoft.Sql", "Microsoft.Storage"]
}

resource "azurerm_subnet" "db" {
  name                 = "db"
  resource_group_name  = azurerm_resource_group.tfe.name
  virtual_network_name = azurerm_virtual_network.tfe.name
  address_prefixes     = ["10.1.2.0/24"]

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
  address_prefixes     = ["10.1.3.0/24"]
}

resource "azurerm_network_security_group" "vm" {
  name                = "${var.friendly_name_prefix}-tfe-vm-nsg"
  location            = azurerm_resource_group.tfe.location
  resource_group_name = azurerm_resource_group.tfe.name
  tags                = merge(var.tags, { managed_by = "terraform" })
}

resource "azurerm_network_security_rule" "tfe_https" {
  name                        = "AllowTfeHttps"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefixes     = var.allowed_ingress_cidrs
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.tfe.name
  network_security_group_name = azurerm_network_security_group.vm.name
}

resource "azurerm_subnet_network_security_group_association" "vm" {
  subnet_id                 = azurerm_subnet.vm.id
  network_security_group_id = azurerm_network_security_group.vm.id
}

# ---------------------------------------------------------------------------
# TFE HVD module — provisions the VMSS, PostgreSQL Flexible Server,
# Azure Cache for Redis, Storage Account, and Load Balancer.
# ---------------------------------------------------------------------------
module "tfe_hvd" {
  source  = "hashicorp/terraform-enterprise-hvd/azurerm"
  version = "1.0.0"

  # Naming & location
  friendly_name_prefix  = var.friendly_name_prefix
  location              = var.location
  resource_group_name   = azurerm_resource_group.tfe.name
  create_resource_group = false
  common_tags           = merge(var.tags, { managed_by = "terraform" })

  # Networking — subnets in the VNet above
  vnet_id         = azurerm_virtual_network.tfe.id
  vm_subnet_id    = azurerm_subnet.vm.id
  db_subnet_id    = azurerm_subnet.db.id
  redis_subnet_id = azurerm_subnet.redis.id

  # Public-facing load balancer (demo). Set lb_is_internal=true and
  # lb_subnet_id for a production internal load balancer.
  lb_is_internal = false

  # DNS — create an A record in the existing Azure public DNS zone
  create_tfe_public_dns_record = true
  public_dns_zone_name         = var.dns_zone_name
  public_dns_zone_rg_name      = var.dns_zone_rg_name
  tfe_fqdn                     = var.tfe_fqdn

  # Bootstrap Key Vault — resolved by name (see data.tf)
  bootstrap_keyvault_name    = var.key_vault_name
  bootstrap_keyvault_rg_name = var.key_vault_rg_name

  # TFE secrets — IDs resolved from data sources (no IDs in workspace variables)
  tfe_license_keyvault_secret_id             = data.azurerm_key_vault_secret.tfe["license"].id
  tfe_encryption_password_keyvault_secret_id = data.azurerm_key_vault_secret.tfe["encryption_password"].id
  tfe_tls_cert_keyvault_secret_id            = data.azurerm_key_vault_secret.tfe["tls_cert"].id
  tfe_tls_privkey_keyvault_secret_id         = data.azurerm_key_vault_secret.tfe["tls_privkey"].id
  tfe_tls_ca_bundle_keyvault_secret_id       = data.azurerm_key_vault_secret.tfe["tls_ca_bundle"].id

  # Database password — the module takes the secret name (not the full ID)
  tfe_database_password_keyvault_secret_name = local.tfe_secret_names["database_password"]

  # Container runtime (docker or podman)
  container_runtime = var.container_runtime

  # Security and recovery defaults
  tfe_image_tag                            = var.tfe_image_tag
  tfe_tls_enforce                          = true
  vm_ssh_public_key                        = var.vm_ssh_public_key
  vm_enable_boot_diagnostics               = true
  storage_account_blob_versioning_enabled  = true
  storage_account_blob_change_feed_enabled = true
}
