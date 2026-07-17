# TFE Secrets Setup

`create_tfe_secrets.sh` is a one-time setup script that creates the Azure Key Vault secrets required by the TFE HVD modules before a `terraform apply`. It accepts a trusted wildcard certificate, key, and CA bundle. If those paths are omitted, it generates self-signed TLS material for sandbox use only.

- **VM** ([`../vm/`](../vm/)) uses the license, encryption password, database password, and TLS secrets.
- **AKS** ([`../aks/`](../aks/)) uses the database password for PostgreSQL, and the tfe layer reads the license, encryption password, database password, and TLS material to populate Kubernetes secrets. Blob Storage uses AKS Workload Identity; the Azure-managed Redis access key is still passed through Terraform state because HVD AKS `0.2.0` has no identity-based Redis option.

Running the script once creates the full superset, so both deployments are covered.

> ⚠️ **Key Vault name uniqueness**: Azure Key Vault names are **globally unique** across all Azure tenants and must be at most 24 characters. Once a vault is deleted, the name is reserved ("soft-deleted") for up to 90 days. Choose a name that is unlikely to conflict, such as `tfe-<yourname>-kv`.

Secrets that already exist are skipped (so re-running is safe). To overwrite existing secrets with newly generated values, pass `--rotate` — the script asks for confirmation first.

> ⚠️ Do not use `--rotate` against a live TFE deployment. Rotating the encryption and database passwords in Key Vault does not automatically update the running instance, which will break TFE.

## Prerequisites

- `az` CLI, authenticated with credentials that have:
  - `Contributor` on the Resource Group (to create the vault)
  - `Key Vault Administrator` or `Key Vault Secrets Officer` on the vault (to create secrets)
- `openssl`
- The Key Vault's Resource Group must already exist before running the script.

## Required environment variables

| Variable | Description |
|---|---|
| `KEY_VAULT_NAME` | Name of the Azure Key Vault (max 24 chars, globally unique). Created if absent. |
| `TFE_HOSTED_ZONE` | Azure DNS public zone the wildcard cert covers (e.g. `example.com`). The cert covers `*.<zone>` and `<zone>` so it serves all TFE subdomains. |
| `KV_RESOURCE_GROUP` | Resource Group where the Key Vault resides (or will be created). Must exist. |
| `KV_LOCATION` | Azure region for Key Vault creation (e.g. `australiaeast`). |
| `TFE_LICENSE_PATH` | Path to your TFE license file (`.hclic`). |

For a trusted certificate, set all three optional variables. The certificate must cover `*.<TFE_HOSTED_ZONE>`, its key must be unencrypted, and the CA bundle must verify it.

| Variable | Description |
|---|---|
| `TLS_CERT_PATH` | PEM wildcard certificate issued by your trusted CA. |
| `TLS_KEY_PATH` | Matching unencrypted PEM private key. |
| `TLS_CA_BUNDLE_PATH` | PEM issuer chain / CA bundle. |

## Usage

```bash
export KEY_VAULT_NAME="tfe-yourname-kv"
export TFE_HOSTED_ZONE="example.com"
export KV_RESOURCE_GROUP="tfe-bootstrap-rg"
export KV_LOCATION="australiaeast"
export TFE_LICENSE_PATH="/path/to/terraform.hclic"
export TLS_CERT_PATH="/path/to/fullchain.pem"
export TLS_KEY_PATH="/path/to/privkey.pem"
export TLS_CA_BUNDLE_PATH="/path/to/ca-bundle.pem"

./scripts/create_tfe_secrets.sh

# To overwrite existing secrets (e.g. before a fresh deployment):
./scripts/create_tfe_secrets.sh --rotate
```

For a throwaway sandbox, omit all three `TLS_*_PATH` variables. The script will warn and generate a private CA. Browsers, Terraform agents, VCS integrations, and API clients will reject it until that CA is installed in every relevant trust store. This is not suitable for production.

The script creates the Key Vault in RBAC authorization mode. For a newly created vault, it grants the signed-in user **Key Vault Secrets Officer** so it can write the bootstrap values. RBAC propagation can take several minutes; a first-run `403` is safe to handle by waiting and rerunning because existing secrets are skipped. Remove that human role after bootstrap if it is no longer required. Grant the HCP Terraform run identity **Key Vault Secrets User** on the vault.

## What gets created

| Secret name | Format | Contents |
|---|---|---|
| `tfe-license` | Plaintext | Raw `.hclic` file contents |
| `tfe-encryption-password` | Plaintext | Randomly generated 32-char password |
| `tfe-database-password` | Plaintext | Randomly generated 24-char password |
| `tfe-tls-cert` | Plaintext (base64) | Supplied trusted or generated sandbox TLS certificate (PEM) |
| `tfe-tls-privkey` | Plaintext (base64) | TLS private key (PEM) |
| `tfe-tls-ca-bundle` | Plaintext (base64) | Self-signed CA certificate (PEM) |

TLS secrets are base64-encoded as required by the VM HVD module. The AKS `tfe` layer decodes them when creating Kubernetes `tls` secrets.

## Workspace RBAC

Terraform workspaces need **Key Vault Secrets User** on the vault to read secret values. Azure Resource Manager lookup of the vault is covered by the deployment identity's Resource Group/subscription Reader or Contributor access.

```sh
az role assignment create \
  --assignee "<application-client-id>" \
  --role "Key Vault Secrets User" \
  --scope "/subscriptions/<sub-id>/resourceGroups/<kv-rg>/providers/Microsoft.KeyVault/vaults/<kv-name>"
```

Secret values read by the AKS TFE workspace are stored in its encrypted HCP Terraform state and in Kubernetes Secrets. Restrict workspace/state access, enable HCP Terraform audit logging where your tier supports it, and enable Kubernetes secrets encryption with customer-managed keys for production. For stronger secret delivery, replace Terraform-managed Kubernetes Secrets with Vault Secrets Operator or the Secrets Store CSI Driver.
