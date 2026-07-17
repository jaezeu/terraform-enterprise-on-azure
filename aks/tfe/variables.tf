variable "tfe_image_tag" {
  type        = string
  default     = "v202505-1"
  description = "Tag (TFE release version) of the terraform-enterprise container image to deploy. See https://developer.hashicorp.com/terraform/enterprise/releases."
}
