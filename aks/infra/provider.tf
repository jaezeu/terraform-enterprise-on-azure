terraform {
  required_version = ">= 1.9"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.116"
    }
  }
  cloud {
    organization = "jaz-hashi"
    workspaces {
      name = "tfe-hvd-aks-infra"
    }
  }
}

# HCP Terraform dynamic provider credentials for Azure — no static secrets stored here.
# Set in the workspace:
#   TFC_AZURE_PROVIDER_AUTH=true
#   TFC_AZURE_RUN_CLIENT_ID=<Entra application/client ID>
provider "azurerm" {
  features {}
}
