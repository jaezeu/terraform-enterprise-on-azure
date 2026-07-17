data "azurerm_client_config" "current" {}

# Bootstrap Key Vault — looked up by name so no IDs are ever workspace variables.
data "azurerm_key_vault" "bootstrap" {
  name                = var.key_vault_name
  resource_group_name = var.key_vault_rg_name
}

# The AKS HVD module reads the database password from Key Vault directly;
# it needs the Key Vault resource ID and the secret name.
# We confirm the secret exists by referencing it via a data source.
data "azurerm_key_vault_secret" "db_password" {
  name         = "tfe-database-password"
  key_vault_id = data.azurerm_key_vault.bootstrap.id
}

# Existing Azure DNS public zone — external-dns will manage records in it.
data "azurerm_dns_zone" "tfe" {
  name                = var.dns_zone_name
  resource_group_name = var.dns_zone_rg_name
}

data "azurerm_resource_group" "dns_zone" {
  name = var.dns_zone_rg_name
}

# After the HVD module creates the AKS cluster, we read the cluster back to
# obtain the OIDC issuer URL used to bind the external-dns federated credential.
# depends_on defers this read to apply time (avoids a plan-time cycle).
data "azurerm_kubernetes_cluster" "tfe" {
  name                = module.tfe_aks.aks_cluster_name
  resource_group_name = azurerm_resource_group.tfe.name

  depends_on = [module.tfe_aks]
}
