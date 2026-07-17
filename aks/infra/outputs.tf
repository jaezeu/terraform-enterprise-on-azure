# Consumed by the addons and tfe layers via terraform_remote_state.
# Enable remote state sharing on workspace tfe-hvd-aks-infra:
#   Settings → General → Remote State Sharing → share with
#   tfe-hvd-aks-addons and tfe-hvd-aks-tfe.

output "aks_cluster_name" {
  description = "Name of the TFE AKS cluster."
  value       = module.tfe_aks.aks_cluster_name
}

output "resource_group_name" {
  description = "Name of the Azure Resource Group for this deployment."
  value       = azurerm_resource_group.tfe.name
}

output "vnet_id" {
  description = "ID of the Azure Virtual Network created for this TFE AKS deployment."
  value       = azurerm_virtual_network.tfe.id
}

output "aks_subnet_id" {
  description = "ID of the AKS subnet."
  value       = azurerm_subnet.aks.id
}

output "tfe_fqdn" {
  description = "FQDN of the TFE instance (single source of truth for downstream layers)."
  value       = var.tfe_fqdn
}

output "dns_zone_name" {
  description = "Azure DNS zone name managed by external-dns."
  value       = var.dns_zone_name
}

output "dns_zone_rg_name" {
  description = "Resource Group name where the Azure DNS zone resides."
  value       = var.dns_zone_rg_name
}

output "external_dns_client_id" {
  description = "Client ID of the external-dns user-assigned managed identity (for Workload Identity annotation)."
  value       = azurerm_user_assigned_identity.external_dns.client_id
}

output "tfe_workload_identity_client_id" {
  description = "Client ID of the TFE workload identity used for Azure Blob Storage."
  value       = module.tfe_aks.tfe_object_storage_azure_client_id
}

output "allowed_ingress_cidrs" {
  description = "Public CIDRs permitted to reach the TFE load balancer."
  value       = var.allowed_ingress_cidrs
}

output "subscription_id" {
  description = "Azure subscription ID (used by external-dns and the tfe layer)."
  value       = data.azurerm_client_config.current.subscription_id
}

output "tenant_id" {
  description = "Azure tenant ID (used by external-dns and the tfe layer)."
  value       = data.azurerm_client_config.current.tenant_id
}

output "key_vault_name" {
  description = "Name of the bootstrap Key Vault (passed downstream to the tfe layer)."
  value       = var.key_vault_name
}

output "key_vault_rg_name" {
  description = "Resource Group name of the bootstrap Key Vault (passed downstream to the tfe layer)."
  value       = var.key_vault_rg_name
}

output "tfe_database_host" {
  description = "FQDN and port of the PostgreSQL Flexible Server for TFE."
  value       = module.tfe_aks.tfe_database_host
}

output "tfe_database_name" {
  description = "PostgreSQL database name for TFE."
  value       = module.tfe_aks.tfe_database_name
}

output "tfe_database_user" {
  description = "PostgreSQL database user for TFE."
  value       = module.tfe_aks.tfe_database_user
}

output "tfe_redis_host" {
  description = "Hostname of the Azure Cache for Redis instance."
  value       = module.tfe_aks.tfe_redis_host
}

output "tfe_redis_password" {
  description = "Primary access key of the Azure Cache for Redis instance (sensitive)."
  value       = module.tfe_aks.tfe_redis_password
  sensitive   = true
}

output "tfe_redis_use_auth" {
  description = "Whether TFE should use authentication to connect to Redis."
  value       = module.tfe_aks.tfe_redis_use_auth
}

output "tfe_storage_account_name" {
  description = "Name of the Azure Storage Account used for TFE object storage."
  value       = module.tfe_aks.tfe_object_storage_azure_account_name
}

output "tfe_storage_container_name" {
  description = "Name of the blob container inside the TFE Storage Account."
  value       = module.tfe_aks.tfe_object_storage_azure_container
}

output "tfe_url" {
  description = "HTTPS URL of the TFE instance."
  value       = "https://${var.tfe_fqdn}"
}
