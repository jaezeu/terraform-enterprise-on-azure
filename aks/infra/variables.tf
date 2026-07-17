variable "friendly_name_prefix" {
  type        = string
  description = "Friendly name prefix for uniquely naming all Azure resources for this deployment. Must differ from the VM deployment's prefix to avoid resource name collisions in the same subscription."

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

variable "aks_kubernetes_version" {
  type        = string
  description = "A non-preview Kubernetes version currently supported by AKS in the selected location. Check with: az aks get-versions --location <location> -o table."

  validation {
    condition     = can(regex("^1\\.[0-9]+(\\.[0-9]+)?$", var.aks_kubernetes_version))
    error_message = "aks_kubernetes_version must be an AKS Kubernetes version such as 1.34 or 1.34.6."
  }
}

variable "aks_api_server_authorized_ip_ranges" {
  type        = list(string)
  description = "CIDRs allowed to reach the public AKS API. Use an empty list only for HCP Terraform hosted runs; for a restricted API, run an HCP Terraform Agent in the VNet and include its egress CIDR."
  default     = []

  validation {
    condition     = alltrue([for cidr in var.aks_api_server_authorized_ip_ranges : can(cidrhost(cidr, 0))])
    error_message = "Every aks_api_server_authorized_ip_ranges value must be valid CIDR notation."
  }
}

variable "allowed_ingress_cidrs" {
  type        = list(string)
  description = "Non-empty list of public CIDRs allowed to reach the TFE Azure Load Balancer. Include users, VCS webhooks, CI systems, and agents that must call TFE."

  validation {
    condition     = length(var.allowed_ingress_cidrs) > 0 && alltrue([for cidr in var.allowed_ingress_cidrs : can(cidrhost(cidr, 0))])
    error_message = "allowed_ingress_cidrs must contain at least one valid CIDR and must not be left open implicitly."
  }
}

variable "tfe_fqdn" {
  type        = string
  description = "Fully qualified domain name of the TFE instance (e.g. tfe-aks.example.com). Must differ from the VM deployment's FQDN. Exposed as an output so the tfe layer reads it from remote state — set it only on this workspace."

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-\\.]{0,251}[a-z0-9])?$", var.tfe_fqdn))
    error_message = "tfe_fqdn must be a valid fully qualified domain name."
  }
}

variable "dns_zone_name" {
  type        = string
  description = "Name of the existing public Azure DNS zone that external-dns will manage TFE records in (e.g. example.com). Shared with the VM deployment."
}

variable "dns_zone_rg_name" {
  type        = string
  description = "Name of the Resource Group where the Azure DNS zone resides."
}

variable "key_vault_name" {
  type        = string
  description = "Name of the Azure Key Vault containing TFE bootstrap secrets (created by scripts/create_tfe_secrets.sh). Exposed as an output so the tfe layer reads it from remote state."
}

variable "key_vault_rg_name" {
  type        = string
  description = "Name of the Resource Group where the bootstrap Key Vault resides. Exposed as an output for downstream layers."
}

variable "tags" {
  type        = map(string)
  description = "Additional tags to apply to all Azure resources."
  default     = {}
}
