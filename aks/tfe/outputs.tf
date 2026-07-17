output "tfe_url" {
  description = "HTTPS URL of the TFE instance."
  value       = "https://${local.infra.tfe_fqdn}"
}
