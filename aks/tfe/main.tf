# Layer 3: TFE application — Kubernetes secrets + the terraform-enterprise
# Helm chart, applied after aks/addons. Values are built from infra outputs.
# DNS comes from external-dns (addons layer) via the Service's hostname annotation —
# the Azure DNS A record is created/maintained automatically.

locals {
  # local.infra: see data.tf

  tfe_namespace        = "tfe"
  tfe_kube_svc_account = "tfe"

  tfe_registry = "images.releases.hashicorp.com"

  # Retrieve secret values only when the infra layer exists.
  tfe_license             = local.infra_exists ? data.azurerm_key_vault_secret.tfe["license"].value : ""
  tfe_encryption_password = local.infra_exists ? data.azurerm_key_vault_secret.tfe["encryption_password"].value : ""
  tfe_database_password   = local.infra_exists ? data.azurerm_key_vault_secret.tfe["database_password"].value : ""

  # TLS: Key Vault stores base64-encoded PEM; Kubernetes secret expects raw PEM.
  tfe_tls_cert_pem = local.infra_exists ? base64decode(data.azurerm_key_vault_secret.tfe["tls_cert"].value) : ""
  tfe_tls_key_pem  = local.infra_exists ? base64decode(data.azurerm_key_vault_secret.tfe["tls_privkey"].value) : ""
  # CA bundle is passed as-is (already base64-encoded) to the Helm chart's tls.caCertData.
  tfe_ca_bundle_b64 = local.infra_exists ? data.azurerm_key_vault_secret.tfe["tls_ca_bundle"].value : ""
}

# ---------------------------------------------------------------------------
# Kubernetes secrets required by the TFE chart.
# ---------------------------------------------------------------------------
resource "kubernetes_namespace_v1" "tfe" {
  metadata {
    name = local.tfe_namespace
  }
}

resource "kubernetes_secret_v1" "tfe_image_pull" {
  metadata {
    name      = "terraform-enterprise"
    namespace = kubernetes_namespace_v1.tfe.metadata[0].name
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        (local.tfe_registry) = {
          username = "terraform"
          password = local.tfe_license
          auth     = base64encode("terraform:${local.tfe_license}")
        }
      }
    })
  }
}

resource "kubernetes_secret_v1" "tfe_secrets" {
  metadata {
    name      = "tfe-secrets"
    namespace = kubernetes_namespace_v1.tfe.metadata[0].name
  }

  data = {
    TFE_LICENSE             = local.tfe_license
    TFE_ENCRYPTION_PASSWORD = local.tfe_encryption_password
    TFE_DATABASE_PASSWORD   = local.tfe_database_password
    TFE_REDIS_PASSWORD      = local.infra.tfe_redis_password
  }
}

resource "kubernetes_secret_v1" "tfe_certs" {
  metadata {
    name      = "tfe-certs"
    namespace = kubernetes_namespace_v1.tfe.metadata[0].name
  }

  type = "kubernetes.io/tls"

  data = {
    "tls.crt" = local.tfe_tls_cert_pem
    "tls.key" = local.tfe_tls_key_pem
  }
}

# ---------------------------------------------------------------------------
# TFE Helm release.
# ---------------------------------------------------------------------------
resource "helm_release" "terraform_enterprise" {
  name       = "terraform-enterprise"
  repository = "https://helm.releases.hashicorp.com"
  chart      = "terraform-enterprise"
  version    = "1.6.2"
  namespace  = kubernetes_namespace_v1.tfe.metadata[0].name

  # First TFE boot runs database migrations — give ample time.
  wait    = true
  timeout = 1800

  values = [yamlencode({
    replicaCount = 1

    tls = {
      certificateSecret = kubernetes_secret_v1.tfe_certs.metadata[0].name
      caCertData        = local.tfe_ca_bundle_b64
    }

    image = {
      repository = local.tfe_registry
      name       = "hashicorp/terraform-enterprise"
      tag        = var.tfe_image_tag
    }

    imagePullSecrets = [{ name = kubernetes_secret_v1.tfe_image_pull.metadata[0].name }]

    serviceAccount = {
      enabled = true
      name    = local.tfe_kube_svc_account
      annotations = {
        "azure.workload.identity/client-id" = local.infra.tfe_workload_identity_client_id
      }
      labels = {
        "azure.workload.identity/use" = "true"
      }
    }

    pod = {
      labels = {
        "azure.workload.identity/use" = "true"
      }
    }

    agents = {
      rbac = {
        enabled = true
      }
    }

    service = {
      type = "LoadBalancer"
      port = 443
      annotations = {
        # external-dns (addons layer) creates/maintains the Azure DNS A record.
        "external-dns.alpha.kubernetes.io/hostname" = local.infra.tfe_fqdn
        # Supported by cloud-provider-azure on Kubernetes 1.29 and later.
        "service.beta.kubernetes.io/azure-allowed-ip-ranges" = join(",", local.infra.allowed_ingress_cidrs)
      }
    }

    env = {
      secretRefs = [{ name = kubernetes_secret_v1.tfe_secrets.metadata[0].name }]

      variables = {
        TFE_HOSTNAME = local.infra.tfe_fqdn

        # Database (PostgreSQL Flexible Server)
        TFE_DATABASE_HOST       = local.infra.tfe_database_host
        TFE_DATABASE_NAME       = local.infra.tfe_database_name
        TFE_DATABASE_USER       = local.infra.tfe_database_user
        TFE_DATABASE_PARAMETERS = "sslmode=require"

        # Object storage (Azure Blob Storage — account key injected via secretRefs)
        TFE_OBJECT_STORAGE_TYPE               = "azure"
        TFE_OBJECT_STORAGE_AZURE_ACCOUNT_NAME = local.infra.tfe_storage_account_name
        TFE_OBJECT_STORAGE_AZURE_CONTAINER    = local.infra.tfe_storage_container_name
        TFE_OBJECT_STORAGE_AZURE_ENDPOINT     = "https://${local.infra.tfe_storage_account_name}.blob.core.windows.net"
        TFE_OBJECT_STORAGE_AZURE_USE_MSI      = "true"
        TFE_OBJECT_STORAGE_AZURE_CLIENT_ID    = local.infra.tfe_workload_identity_client_id

        # Redis (auth + TLS — access key injected via secretRefs as TFE_REDIS_PASSWORD)
        TFE_REDIS_HOST     = local.infra.tfe_redis_host
        TFE_REDIS_USE_AUTH = tostring(local.infra.tfe_redis_use_auth)
        TFE_REDIS_USE_TLS  = "true"
      }
    }
  })]
}
