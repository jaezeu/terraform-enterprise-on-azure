variable "friendly_name_prefix" {
  type        = string
  description = "Friendly name prefix used for uniquely naming all Azure resources for this deployment. Must differ from the AKS deployment's prefix to avoid resource name collisions in the same subscription."

  validation {
    condition     = can(regex("^[a-z0-9]{1,17}$", var.friendly_name_prefix))
    error_message = "friendly_name_prefix must be 1-17 lowercase letters or digits because it is used in a globally unique Azure Storage Account name."
  }
}

variable "location" {
  type        = string
  description = "Azure region for this TFE deployment (e.g. australiaeast)."
  default     = "australiaeast"
}

variable "tfe_fqdn" {
  type        = string
  description = "Fully qualified domain name of the TFE instance (e.g. tfe-vm.example.com). Must differ from the AKS deployment's FQDN so both coexist in the same subscription."

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-\\.]{0,251}[a-z0-9])?$", var.tfe_fqdn))
    error_message = "tfe_fqdn must be a valid fully qualified domain name."
  }
}

variable "dns_zone_name" {
  type        = string
  description = "Name of the existing public Azure DNS zone that TFE DNS records will be created in (e.g. example.com). Shared with the AKS deployment."
}

variable "dns_zone_rg_name" {
  type        = string
  description = "Name of the Resource Group where the Azure DNS zone resides."
}

variable "key_vault_name" {
  type        = string
  description = "Name of the Azure Key Vault containing TFE bootstrap secrets (created by scripts/create_tfe_secrets.sh). Must be globally unique and at most 24 characters."
}

variable "key_vault_rg_name" {
  type        = string
  description = "Name of the Resource Group where the bootstrap Key Vault resides."
}

variable "container_runtime" {
  type        = string
  description = "Container runtime for the TFE VM. Use 'docker' for Ubuntu or 'podman'/'docker' for RHEL."
  default     = "docker"

  validation {
    condition     = contains(["docker", "podman"], var.container_runtime)
    error_message = "container_runtime must be 'docker' or 'podman'."
  }
}

variable "tfe_image_tag" {
  type        = string
  description = "Pinned Terraform Enterprise container image tag. Review the required upgrade path before changing it."
  default     = "v202505-1"

  validation {
    condition     = can(regex("^v(20[0-9]{4}-[0-9]+|[0-9]+\\.[0-9]+\\.[0-9]+)$", var.tfe_image_tag))
    error_message = "tfe_image_tag must be a calendar tag such as v202505-1 or a semantic tag such as v1.2.4."
  }
}

variable "allowed_ingress_cidrs" {
  type        = list(string)
  description = "Non-empty list of public CIDR ranges allowed to reach TFE over HTTPS. Include users, VCS webhooks, CI systems, and agents that must call TFE."

  validation {
    condition     = length(var.allowed_ingress_cidrs) > 0 && alltrue([for cidr in var.allowed_ingress_cidrs : can(cidrhost(cidr, 0))])
    error_message = "allowed_ingress_cidrs must contain at least one valid CIDR and must not be left open implicitly."
  }
}

variable "vm_ssh_public_key" {
  type        = string
  description = "SSH public key for the TFE VMSS administrator. SSH is not opened to the internet; use Azure Bastion or private VNet access."
  sensitive   = true

  validation {
    condition     = can(regex("^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521)) ", trimspace(var.vm_ssh_public_key)))
    error_message = "vm_ssh_public_key must be a valid OpenSSH public key."
  }
}

variable "tags" {
  type        = map(string)
  description = "Additional tags to apply to all Azure resources."
  default     = {}
}
