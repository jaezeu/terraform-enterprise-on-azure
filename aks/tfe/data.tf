# Outputs of the infra layer (cluster, endpoints, Key Vault, storage, etc.).
# Requires remote state sharing to be enabled on the tfe-hvd-aks-infra
# workspace for this workspace.
data "terraform_remote_state" "infra" {
  backend = "remote"

  config = {
    organization = "jaz-hashi"
    workspaces = {
      name = "tfe-hvd-aks-infra"
    }
  }
}

# try(): if infra was already destroyed its outputs are gone, but this layer
# must still be able to plan its own destroy.
locals {
  infra_outputs = data.terraform_remote_state.infra.outputs
  infra_exists  = can(local.infra_outputs.aks_cluster_name)
  infra = {
    aks_cluster_name                = try(local.infra_outputs.aks_cluster_name, "unused")
    resource_group_name             = try(local.infra_outputs.resource_group_name, "unused")
    tfe_fqdn                        = try(local.infra_outputs.tfe_fqdn, "unused")
    allowed_ingress_cidrs           = try(local.infra_outputs.allowed_ingress_cidrs, [])
    key_vault_name                  = try(local.infra_outputs.key_vault_name, "unused")
    key_vault_rg_name               = try(local.infra_outputs.key_vault_rg_name, "unused")
    tfe_database_host               = try(local.infra_outputs.tfe_database_host, "unused")
    tfe_database_name               = try(local.infra_outputs.tfe_database_name, "tfe")
    tfe_database_user               = try(local.infra_outputs.tfe_database_user, "tfe")
    tfe_redis_host                  = try(local.infra_outputs.tfe_redis_host, "unused")
    tfe_redis_password              = try(local.infra_outputs.tfe_redis_password, "")
    tfe_redis_use_auth              = try(local.infra_outputs.tfe_redis_use_auth, true)
    tfe_storage_account_name        = try(local.infra_outputs.tfe_storage_account_name, "unused")
    tfe_storage_container_name      = try(local.infra_outputs.tfe_storage_container_name, "unused")
    tfe_workload_identity_client_id = try(local.infra_outputs.tfe_workload_identity_client_id, "unused")
  }
}

# Bootstrap Key Vault — resolved from infra remote state (no KV name in tfe workspace variables).
data "azurerm_key_vault" "bootstrap" {
  count               = local.infra_exists ? 1 : 0
  name                = local.infra.key_vault_name
  resource_group_name = local.infra.key_vault_rg_name
}

# Secret VALUES consumed by Kubernetes secrets + the Helm install.
# The run role needs Key Vault Secrets User on the bootstrap vault.
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
  for_each     = local.infra_exists ? local.tfe_secret_names : {}
  name         = each.value
  key_vault_id = data.azurerm_key_vault.bootstrap[0].id
}

# count-gated: AKS cluster lookup fails hard when the cluster is gone.
data "azurerm_kubernetes_cluster" "tfe" {
  count               = local.infra_exists ? 1 : 0
  name                = local.infra.aks_cluster_name
  resource_group_name = local.infra.resource_group_name
}
