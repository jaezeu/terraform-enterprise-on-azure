# Look up the bootstrap Key Vault by name — no Key Vault IDs or secret IDs
# are ever stored in workspace variables.
data "azurerm_key_vault" "bootstrap" {
  name                = var.key_vault_name
  resource_group_name = var.key_vault_rg_name
}

# Resolve each TFE secret by name from the Key Vault. The HVD module requires
# full Key Vault secret IDs (versionless) for most secrets; we derive them
# here so no ARN/ID ever needs to be copied into workspace variables.
locals {
  tfe_secret_names = {
    license             = "tfe-license"
    encryption_password = "tfe-encryption-password"
    database_password   = "tfe-database-password"
    tls_cert            = "tfe-tls-cert"
    tls_privkey         = "tfe-tls-privkey"
    tls_ca_bundle       = "tfe-tls-ca-bundle"
  }
}

data "azurerm_key_vault_secret" "tfe" {
  for_each     = local.tfe_secret_names
  name         = each.value
  key_vault_id = data.azurerm_key_vault.bootstrap.id
}
