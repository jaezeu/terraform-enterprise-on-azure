# Terraform Enterprise on Azure AKS

Deploys HashiCorp Terraform Enterprise (TFE) on AKS in **three layered HCP Terraform workspaces**, applied in order. Layering keeps the cluster and its in-cluster resources in separate states (avoiding the Terraform "stacking" anti-pattern), keeps each apply short, and lets app changes plan in seconds without touching infrastructure.

| Layer | Directory | Workspace | Contents |
|---|---|---|---|
| 1. Infra | [`infra/`](infra/) | `tfe-hvd-aks-infra` | VNet, [HVD module](https://registry.terraform.io/modules/hashicorp/terraform-enterprise-aks-hvd/azurerm/latest) (AKS, PostgreSQL Flexible Server, Redis, Storage Account), external-dns managed identity + federated credential |
| 2. Addons | [`addons/`](addons/) | `tfe-hvd-aks-addons` | external-dns (Azure Workload Identity) |
| 3. TFE | [`tfe/`](tfe/) | `tfe-hvd-aks-tfe` | Kubernetes secrets (from Key Vault), TFE Helm chart |

Downstream layers read the infra workspace's outputs via `terraform_remote_state` — cluster name, endpoints, storage account details, and `tfe_fqdn` flow from one source of truth. **DNS:** the TFE Service carries an `external-dns.alpha.kubernetes.io/hostname` annotation; external-dns watches it and creates/maintains the Azure DNS A record automatically. No Terraform DNS resource — the record self-heals if the Load Balancer IP ever changes.

---

## One-time setup

1. **Secrets** — run [`../scripts/create_tfe_secrets.sh`](../scripts/) once (creates 6 secrets; provide trusted wildcard TLS files or accept the sandbox-only self-signed fallback).
2. **Role assignments** — the run identity needs:
   - `Contributor` on the subscription (from the OIDC bootstrap — see root README)
   - `Key Vault Secrets User` on the bootstrap Key Vault (see scripts/README.md)
3. **Remote state sharing** — on workspace `tfe-hvd-aks-infra` → Settings → General → Remote State Sharing: share with `tfe-hvd-aks-addons` and `tfe-hvd-aks-tfe`.
4. **Infra variables** — set `friendly_name_prefix`, `tfe_fqdn`, zone and Key Vault values, `aks_kubernetes_version`, and `allowed_ingress_cidrs`. Select a currently supported version with `az aks get-versions --location <location> -o table`; do not reuse the module's retired `1.29.6` default.
5. **AKS API access** — `aks_api_server_authorized_ip_ranges = []` is compatible with HCP Terraform hosted runs but leaves the API publicly reachable and protected only by AKS authentication. HCP Terraform does not publish hosted-run execution IPs. For a restricted/private control plane, use an HCP Terraform Agent with VNet reachability and include only its/user egress CIDRs.

## Security posture and limits

- TFE has one public Azure Load Balancer. The `azure-allowed-ip-ranges` annotation restricts it to `allowed_ingress_cidrs`; include every user, VCS webhook, CI system, and agent that needs TFE. Avoid `0.0.0.0/0` outside a disposable sandbox.
- Blob Storage uses AKS Workload Identity, so no storage account key is copied into downstream state or Kubernetes Secrets. AzureRM still records the generated key in infra state. PostgreSQL, Redis, and Blob Storage use private endpoints by module default.
- The Redis access key, TFE license, encryption/database passwords, and TLS private key still exist in encrypted HCP Terraform state and Kubernetes Secrets. Restrict state access and Kubernetes RBAC. For production, use Vault Secrets Operator or Secrets Store CSI and enable Kubernetes secrets encryption with a customer-managed key.
- The Helm providers currently use AKS admin kubeconfig credentials fetched at run time. They are not persisted as Terraform outputs, but the run identity requires `listClusterAdminCredential/action` and has cluster-admin capability during runs. A production design should use an HCP Agent and scoped Kubernetes/Entra RBAC instead.
- TFE runs one replica. The infrastructure module creates two nodes per pool but PostgreSQL HA is disabled by default. This is not production HA or DR.
- PostgreSQL backup retention defaults to 35 days and geo-redundant backup is enabled. Restore testing, RTO/RPO, cross-region failover, alerting, and runbooks are not implemented.
- Azure Monitor/Container Insights, TFE metrics scraping, alerts, Network Policy, Defender for Containers, and image admission/signature policy are not configured.
- AKS HVD `0.2.0` is pinned to AzureRM v3 and contains a known deprecation warning. Re-evaluate the module, Kubernetes version, and provider lock before every new deployment.

---

## Deploy

Apply the layers in order (each directory is CLI-driven against its workspace):

```sh
cd infra   && terraform init && terraform apply   # ~30-40 min (AKS, PostgreSQL, Redis)
cd ../addons && terraform init && terraform apply  # ~3-5 min
cd ../tfe    && terraform init && terraform apply  # ~10-20 min (image pull, DB migrations, LB)
```

A few minutes after the tfe layer finishes, external-dns will have created the Azure DNS A record and `https://<tfe_fqdn>` is live. Destroy in reverse order (`tfe` → `addons` → `infra`).

### First-time setup: initial admin user

TFE is bootstrapped with the Initial Admin Creation Token (IACT), retrieved from the TFE pod with `tfectl`.

**1. Get credentials for the AKS cluster** (once):

```sh
az aks get-credentials \
  --resource-group <friendly_name_prefix>-tfe-aks-rg \
  --name <aks_cluster_name from infra outputs>
```

**2. Retrieve the IACT token from the pod:**

```sh
kubectl exec -it -n tfe deploy/terraform-enterprise -- tfectl admin token
```

**3. Create the admin user** by opening:

```
https://<tfe_fqdn>/admin/account/new?token=<TOKEN>
```

Notes:
- The IACT is retrievable for **60 minutes after the app starts** and stops working once the first admin user is created.
- Missed the window? Restart the pod (safe in external-services mode — all data in PostgreSQL/Storage/Redis):

  ```sh
  kubectl rollout restart deploy/terraform-enterprise -n tfe
  kubectl exec -it -n tfe deploy/terraform-enterprise -- tfectl admin token
  ```

---

## Variables (per workspace)

| Workspace | Variable | Required | Notes |
|---|---|---|---|
| infra | `friendly_name_prefix` | yes | 1-17 lowercase alphanumeric characters, no hyphens; must differ from VM |
| infra | `tfe_fqdn` | yes | downstream layers read it from remote state |
| infra | `dns_zone_name` | yes | Azure DNS zone external-dns manages |
| infra | `dns_zone_rg_name` | yes | Resource Group of the DNS zone |
| infra | `key_vault_name` | yes | ≤ 24 chars, globally unique |
| infra | `key_vault_rg_name` | yes | Resource Group of the Key Vault |
| infra | `aks_kubernetes_version` | yes | currently supported non-preview AKS version in the chosen region |
| infra | `allowed_ingress_cidrs` | yes | public CIDRs allowed to reach TFE HTTPS |
| infra | `aks_api_server_authorized_ip_ranges` | no | AKS API allowlist; empty for hosted runs, restricted for VNet agents |
| tfe | `tfe_image_tag` | no | default `v202505-1` |
| addons | — | — | everything comes from remote state |

All three workspaces carry the `TFC_AZURE_PROVIDER_AUTH` / `TFC_AZURE_RUN_CLIENT_ID` env vars.

---

## Sources

| Component | Source | Version |
|---|---|---|
| `tfe_aks` module | [hashicorp/terraform-enterprise-aks-hvd/azurerm](https://registry.terraform.io/modules/hashicorp/terraform-enterprise-aks-hvd/azurerm/0.2.0) | `0.2.0` |
| TFE Helm chart | [hashicorp/terraform-enterprise](https://helm.releases.hashicorp.com) | `1.6.2` (documented pair for `v202505-1`) |
| TFE container | [Terraform Enterprise releases](https://developer.hashicorp.com/terraform/enterprise/releases) | `v202505-1` by default |
| external-dns chart | [kubernetes-sigs/external-dns](https://kubernetes-sigs.github.io/external-dns/) | `1.21.1` |

VNet CIDR is `10.0.0.0/16` — separate from the VM deployment (`10.1.0.0/16`), so no address-space conflict (and they can never be peered without re-addressing).
