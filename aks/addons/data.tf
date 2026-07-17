# Outputs of the infra layer. Requires remote state sharing to be enabled on
# the tfe-hvd-aks-infra workspace for this workspace. Reads authenticate
# automatically inside HCP Terraform runs.
data "terraform_remote_state" "infra" {
  backend = "remote"

  config = {
    organization = "jaz-hashi"
    workspaces = {
      name = "tfe-hvd-aks-infra"
    }
  }
}

# try(): if the infra workspace was already destroyed its outputs are gone, but
# this layer must still be able to plan its own destroy.
locals {
  infra_outputs = data.terraform_remote_state.infra.outputs
  infra_exists  = can(local.infra_outputs.aks_cluster_name)
  infra = {
    aks_cluster_name       = try(local.infra_outputs.aks_cluster_name, "unused")
    resource_group_name    = try(local.infra_outputs.resource_group_name, "unused")
    dns_zone_name          = try(local.infra_outputs.dns_zone_name, "unused")
    dns_zone_rg_name       = try(local.infra_outputs.dns_zone_rg_name, "unused")
    external_dns_client_id = try(local.infra_outputs.external_dns_client_id, "unused")
    subscription_id        = try(local.infra_outputs.subscription_id, "unused")
    tenant_id              = try(local.infra_outputs.tenant_id, "unused")
    tfe_fqdn               = try(local.infra_outputs.tfe_fqdn, "unused")
  }
}

# count-gated: fails hard when the cluster is gone; skip when infra is absent.
data "azurerm_kubernetes_cluster" "tfe" {
  count               = local.infra_exists ? 1 : 0
  name                = local.infra.aks_cluster_name
  resource_group_name = local.infra.resource_group_name
}
