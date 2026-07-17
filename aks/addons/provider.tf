terraform {
  required_version = ">= 1.9"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.116"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
  }
  cloud {
    organization = "jaz-hashi"
    workspaces {
      name = "tfe-hvd-aks-addons"
    }
  }
}

# HCP Terraform dynamic provider credentials — no static secrets.
provider "azurerm" {
  features {}
}

# Authenticates to the AKS cluster using the admin kubeconfig obtained from
# the Azure provider. try(): the data sources are count-gated and absent once
# the cluster is destroyed, so the placeholders keep destroy plans working.
# This requires listClusterAdminCredential/action and gives the run temporary
# cluster-admin capability. See the AKS README for the production agent/RBAC path.
provider "kubernetes" {
  host = try(
    data.azurerm_kubernetes_cluster.tfe[0].kube_config[0].host,
    "https://cluster-gone.invalid"
  )
  cluster_ca_certificate = try(
    base64decode(data.azurerm_kubernetes_cluster.tfe[0].kube_config[0].cluster_ca_certificate),
    ""
  )
  client_certificate = try(
    base64decode(data.azurerm_kubernetes_cluster.tfe[0].kube_config[0].client_certificate),
    ""
  )
  client_key = try(
    base64decode(data.azurerm_kubernetes_cluster.tfe[0].kube_config[0].client_key),
    ""
  )
  username = try(data.azurerm_kubernetes_cluster.tfe[0].kube_config[0].username, "")
  password = try(data.azurerm_kubernetes_cluster.tfe[0].kube_config[0].password, "")
}

provider "helm" {
  kubernetes = {
    host = try(
      data.azurerm_kubernetes_cluster.tfe[0].kube_config[0].host,
      "https://cluster-gone.invalid"
    )
    cluster_ca_certificate = try(
      base64decode(data.azurerm_kubernetes_cluster.tfe[0].kube_config[0].cluster_ca_certificate),
      ""
    )
    client_certificate = try(
      base64decode(data.azurerm_kubernetes_cluster.tfe[0].kube_config[0].client_certificate),
      ""
    )
    client_key = try(
      base64decode(data.azurerm_kubernetes_cluster.tfe[0].kube_config[0].client_key),
      ""
    )
    username = try(data.azurerm_kubernetes_cluster.tfe[0].kube_config[0].username, "")
    password = try(data.azurerm_kubernetes_cluster.tfe[0].kube_config[0].password, "")
  }
}
