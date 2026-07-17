# Layer 2: cluster addons — external-dns.
# Applied after aks/infra. external-dns uses Azure Workload Identity
# (the managed identity + federated credential created in the infra layer)
# to manage Azure DNS records — no client secrets ever stored.
#
# Unlike the AWS implementation, AKS provisions the Azure Load Balancer directly
# from TFE's Service. external-dns watches that Service and keeps its DNS record
# in sync.

# local.infra — see data.tf

resource "kubernetes_namespace_v1" "external_dns" {
  metadata {
    name = "external-dns"
  }
}

resource "kubernetes_secret_v1" "external_dns_azure" {
  metadata {
    name      = "external-dns-azure"
    namespace = kubernetes_namespace_v1.external_dns.metadata[0].name
  }

  data = {
    "azure.json" = jsonencode({
      tenantId                     = local.infra.tenant_id
      subscriptionId               = local.infra.subscription_id
      resourceGroup                = local.infra.dns_zone_rg_name
      useWorkloadIdentityExtension = true
    })
  }
}

# ---------------------------------------------------------------------------
# external-dns — manages Azure DNS records from Service/Ingress annotations.
# Uses Azure Workload Identity (no client secret): the service account is
# annotated with the managed identity's client ID, and the pod is labeled
# azure.workload.identity/use=true so the AKS mutating webhook injects the
# OIDC token.
#
# Azure/Entra federated identity credentials do NOT support wildcard subjects
# (unlike AWS IAM trust-policy conditions which can use StringLike with *).
# Each workload needs an explicit federated credential — see root README for
# the HCP TF bootstrap bootstrap_federated_credentials block.
# ---------------------------------------------------------------------------
resource "helm_release" "external_dns" {
  name       = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  version    = "1.21.1"
  namespace  = kubernetes_namespace_v1.external_dns.metadata[0].name

  wait    = true
  timeout = 600

  values = [yamlencode({
    provider = {
      name = "azure"
    }
    serviceAccount = {
      create = true
      name   = "external-dns"
      labels = {
        "azure.workload.identity/use" = "true"
      }
      annotations = {
        # Azure Workload Identity uses this annotation to map the K8s service
        # account to the managed identity created in the infra layer.
        "azure.workload.identity/client-id" = local.infra.external_dns_client_id
      }
    }
    # Required label for the AKS Workload Identity mutating webhook to inject
    # the OIDC token into the external-dns pod.
    podLabels = {
      "azure.workload.identity/use" = "true"
    }
    extraVolumes = [{
      name = "azure-config-file"
      secret = {
        secretName = kubernetes_secret_v1.external_dns_azure.metadata[0].name
      }
    }]
    extraVolumeMounts = [{
      name      = "azure-config-file"
      mountPath = "/etc/kubernetes"
      readOnly  = true
    }]
    # sync removes stale DNS records when Services are deleted.
    sources       = ["service"]
    policy        = "sync"
    txtOwnerId    = local.infra.aks_cluster_name
    domainFilters = [local.infra.dns_zone_name]
  })]
}
