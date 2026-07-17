output "tfe_url" {
  description = "HTTPS URL of the TFE instance."
  value       = "https://${var.tfe_fqdn}"
}

output "resource_group_name" {
  description = "Name of the Azure Resource Group for this deployment."
  value       = azurerm_resource_group.tfe.name
}

output "vnet_id" {
  description = "ID of the Azure Virtual Network created for this TFE VM deployment."
  value       = azurerm_virtual_network.tfe.id
}

output "vm_subnet_id" {
  description = "ID of the VM subnet."
  value       = azurerm_subnet.vm.id
}

output "db_subnet_id" {
  description = "ID of the database subnet (PostgreSQL Flexible Server)."
  value       = azurerm_subnet.db.id
}

output "redis_subnet_id" {
  description = "ID of the Redis subnet."
  value       = azurerm_subnet.redis.id
}
