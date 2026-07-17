#!/usr/bin/env bash
# =============================================================================
# create_tfe_secrets.sh
# Creates the Azure Key Vault secrets required by the TFE HVD modules.
# Uses caller-supplied TLS files when provided, or generates a self-signed CA
# and wildcard certificate for sandbox use.
#
# Secrets that already exist are left untouched by default, so re-running is
# safe. Pass --rotate to overwrite existing values — do NOT do this against a
# live TFE deployment: rotating the encryption and database passwords without
# updating the running instance will break TFE.
#
# Prerequisites:
#   - az CLI (authenticated with appropriate credentials)
#   - openssl
#
# Required env vars:
#   KEY_VAULT_NAME      Globally unique Azure Key Vault name (max 24 chars).
#                       The script creates the vault if it does not exist.
#                       ⚠️  Key Vault names are globally unique across ALL
#                       Azure tenants and cannot be reused for 90 days after
#                       deletion ("soft-delete"). Choose a unique name, e.g.
#                       tfe-demo-<yourname>-kv (keep it ≤ 24 characters).
#   TFE_HOSTED_ZONE     Public Azure DNS zone the wildcard cert covers (e.g.
#                       example.com). The cert covers *.<zone> and <zone>.
#   KV_RESOURCE_GROUP   Resource Group where the Key Vault resides (or will
#                       be created). Must already exist.
#   KV_LOCATION         Azure region for Key Vault creation (e.g. australiaeast).
#   TFE_LICENSE_PATH    Path to your TFE license file (.hclic).
#
# Optional TLS env vars (set all three or none):
#   TLS_CERT_PATH       PEM certificate covering *.<TFE_HOSTED_ZONE>.
#   TLS_KEY_PATH        Unencrypted PEM private key for TLS_CERT_PATH.
#   TLS_CA_BUNDLE_PATH  PEM CA chain that verifies TLS_CERT_PATH.
#
# Usage:
#   ./create_tfe_secrets.sh [--rotate]
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "[INFO]  $*" >&2; }
warn() { echo "[WARN]  $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

require() {
  for cmd in "$@"; do
    command -v "$cmd" &>/dev/null || die "'$cmd' not found — please install it first."
  done
}

# Creates or updates a Key Vault secret.
# Usage: set_secret <name> <value>
set_secret() {
  local name="$1"
  local value="$2"

  # Check if secret already exists (returns empty if not)
  local existing
  existing="$(az keyvault secret show \
    --vault-name "$KEY_VAULT_NAME" \
    --name "$name" \
    --query "id" \
    --output tsv 2>/dev/null || true)"

  if [[ -n "$existing" ]]; then
    if [[ "$ROTATE" == "true" ]]; then
      log "Secret '$name' already exists — rotating (--rotate)."
      az keyvault secret set \
        --vault-name "$KEY_VAULT_NAME" \
        --name "$name" \
        --value "$value" \
        --output none
    else
      log "Secret '$name' already exists — skipping (pass --rotate to overwrite)."
      return 0
    fi
  else
    log "Creating secret '$name'."
    az keyvault secret set \
      --vault-name "$KEY_VAULT_NAME" \
      --name "$name" \
      --value "$value" \
      --output none
  fi
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
ROTATE=false
for arg in "$@"; do
  case "$arg" in
    --rotate) ROTATE=true ;;
    *) die "Unknown argument: '$arg' (usage: $0 [--rotate])" ;;
  esac
done

if [[ "$ROTATE" == "true" ]]; then
  log "--rotate: existing secrets WILL be overwritten with new values."
  log "Do NOT do this against a live TFE deployment — rotating the encryption"
  log "and database passwords without updating TFE will break it."
  read -r -p "Type 'rotate' to continue: " confirm
  [[ "$confirm" == "rotate" ]] || die "Aborted."
fi

# ---------------------------------------------------------------------------
# Preflight: required tools and env vars
# ---------------------------------------------------------------------------
require az openssl

[[ -z "${KEY_VAULT_NAME:-}"    ]] && die "KEY_VAULT_NAME is not set."
[[ -z "${TFE_HOSTED_ZONE:-}"   ]] && die "TFE_HOSTED_ZONE is not set."
[[ -z "${KV_RESOURCE_GROUP:-}" ]] && die "KV_RESOURCE_GROUP is not set."
[[ -z "${KV_LOCATION:-}"       ]] && die "KV_LOCATION is not set."
[[ -z "${TFE_LICENSE_PATH:-}"  ]] && die "TFE_LICENSE_PATH is not set."
[[ -f "$TFE_LICENSE_PATH"      ]] || die "TFE_LICENSE_PATH file not found: $TFE_LICENSE_PATH"

TLS_INPUT_COUNT=0
for tls_var in TLS_CERT_PATH TLS_KEY_PATH TLS_CA_BUNDLE_PATH; do
  [[ -n "${!tls_var:-}" ]] && TLS_INPUT_COUNT=$((TLS_INPUT_COUNT + 1))
done
[[ "$TLS_INPUT_COUNT" -eq 0 || "$TLS_INPUT_COUNT" -eq 3 ]] || \
  die "Set TLS_CERT_PATH, TLS_KEY_PATH, and TLS_CA_BUNDLE_PATH together, or leave all three unset for sandbox self-signed TLS."

# Validate Key Vault name length (Azure enforces 3–24 characters).
KV_NAME_LEN="${#KEY_VAULT_NAME}"
if [[ "$KV_NAME_LEN" -gt 24 ]]; then
  die "KEY_VAULT_NAME '$KEY_VAULT_NAME' is ${KV_NAME_LEN} characters — Azure enforces a maximum of 24."
fi
if [[ "$KV_NAME_LEN" -lt 3 ]]; then
  die "KEY_VAULT_NAME '$KEY_VAULT_NAME' is ${KV_NAME_LEN} characters — Azure enforces a minimum of 3."
fi
if [[ ! "$KEY_VAULT_NAME" =~ ^[A-Za-z][A-Za-z0-9-]*[A-Za-z0-9]$ || "$KEY_VAULT_NAME" == *--* ]]; then
  die "KEY_VAULT_NAME must start with a letter, end with a letter or digit, contain only letters/digits/hyphens, and have no consecutive hyphens."
fi
if [[ ! "$TFE_HOSTED_ZONE" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]; then
  die "TFE_HOSTED_ZONE must be a valid DNS zone name without a scheme, path, wildcard, or trailing dot."
fi

TFE_LICENSE_CONTENT="$(cat "$TFE_LICENSE_PATH")"
WILDCARD_DOMAIN="*.${TFE_HOSTED_ZONE}"
TMPDIR_WORK="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_WORK"' EXIT

log "Key Vault name:  $KEY_VAULT_NAME"
log "Resource Group:  $KV_RESOURCE_GROUP"
log "Location:        $KV_LOCATION"
log "Hosted zone:     $TFE_HOSTED_ZONE"
log "Cert domains:    $WILDCARD_DOMAIN, $TFE_HOSTED_ZONE"
log "License file:    $TFE_LICENSE_PATH"
echo

# ---------------------------------------------------------------------------
# Create Key Vault if it does not exist (RBAC authorization mode).
# RBAC mode is required so that Terraform workloads can be granted the
# "Key Vault Secrets User" built-in role rather than legacy access policies.
# ---------------------------------------------------------------------------
if ! az keyvault show --name "$KEY_VAULT_NAME" --resource-group "$KV_RESOURCE_GROUP" \
     --output none 2>/dev/null; then
  log "Key Vault '$KEY_VAULT_NAME' not found — creating in '$KV_RESOURCE_GROUP' ($KV_LOCATION)..."
  az keyvault create \
    --name "$KEY_VAULT_NAME" \
    --resource-group "$KV_RESOURCE_GROUP" \
    --location "$KV_LOCATION" \
    --enable-rbac-authorization true \
    --output none
  log "Key Vault created."

  CURRENT_USER_OBJECT_ID="$(az ad signed-in-user show --query id --output tsv)"
  KEY_VAULT_ID="$(az keyvault show \
    --name "$KEY_VAULT_NAME" \
    --resource-group "$KV_RESOURCE_GROUP" \
    --query id \
    --output tsv)"
  log "Granting the signed-in user Key Vault Secrets Officer on the new vault..."
  az role assignment create \
    --assignee-object-id "$CURRENT_USER_OBJECT_ID" \
    --assignee-principal-type User \
    --role "Key Vault Secrets Officer" \
    --scope "$KEY_VAULT_ID" \
    --output none
  warn "Azure RBAC propagation can take several minutes. If the first secret write"
  warn "returns 403, wait for propagation and rerun this script; existing values are skipped."
else
  log "Key Vault '$KEY_VAULT_NAME' already exists."
fi

# ---------------------------------------------------------------------------
# Generate passwords
# ---------------------------------------------------------------------------
ENCRYPTION_PASSWORD="$(openssl rand -hex 16)"
log "Generated encryption password."

# Avoid '$' which can confuse PostgreSQL Flexible Server connection strings.
DB_PASSWORD="$(openssl rand -hex 16)"
log "Generated database password."

# ---------------------------------------------------------------------------
# TLS cert + private key
# ---------------------------------------------------------------------------
CA_KEY="$TMPDIR_WORK/ca.key"
CA_CERT="$TMPDIR_WORK/ca.crt"
TLS_KEY="$TMPDIR_WORK/tfe.key"
TLS_CSR="$TMPDIR_WORK/tfe.csr"
TLS_CERT="$TMPDIR_WORK/tfe.crt"
EXT_FILE="$TMPDIR_WORK/tfe.ext"

if [[ "$TLS_INPUT_COUNT" -eq 3 ]]; then
  for tls_file in "$TLS_CERT_PATH" "$TLS_KEY_PATH" "$TLS_CA_BUNDLE_PATH"; do
    [[ -f "$tls_file" ]] || die "TLS input file not found: $tls_file"
  done

  cp "$TLS_CERT_PATH" "$TLS_CERT"
  cp "$TLS_KEY_PATH" "$TLS_KEY"
  cp "$TLS_CA_BUNDLE_PATH" "$CA_CERT"

  log "Validating supplied TLS certificate, key, and CA bundle..."
  openssl x509 -in "$TLS_CERT" -noout >/dev/null 2>&1 || die "TLS_CERT_PATH is not a valid PEM certificate."
  openssl pkey -in "$TLS_KEY" -noout >/dev/null 2>&1 || die "TLS_KEY_PATH is not a valid unencrypted PEM private key."
  openssl verify -CAfile "$CA_CERT" "$TLS_CERT" >/dev/null 2>&1 || die "TLS_CA_BUNDLE_PATH does not verify TLS_CERT_PATH."
  openssl x509 -in "$TLS_CERT" -noout -checkhost "tfe-cert-check.${TFE_HOSTED_ZONE}" >/dev/null 2>&1 || \
    die "TLS_CERT_PATH must cover *.${TFE_HOSTED_ZONE} so both deployments can share it."

  openssl x509 -in "$TLS_CERT" -pubkey -noout > "$TMPDIR_WORK/cert.pub"
  openssl pkey -in "$TLS_KEY" -pubout > "$TMPDIR_WORK/key.pub" 2>/dev/null
  cmp -s "$TMPDIR_WORK/cert.pub" "$TMPDIR_WORK/key.pub" || die "TLS_KEY_PATH does not match TLS_CERT_PATH."
  log "Using caller-supplied trusted TLS material."
else
  warn "No TLS paths supplied: generating a self-signed certificate for sandbox use."
  warn "Clients must trust the generated CA manually. Do not use this mode for production."

  openssl genrsa -out "$CA_KEY" 4096 2>/dev/null
  openssl req -x509 -new -nodes \
    -key "$CA_KEY" \
    -sha256 -days 3650 \
    -subj "/C=AU/O=HashiCorp Sandbox/CN=TFE Sandbox CA" \
    -out "$CA_CERT" 2>/dev/null

  log "Generating TLS private key + CSR for $WILDCARD_DOMAIN..."
  openssl genrsa -out "$TLS_KEY" 4096 2>/dev/null
  openssl req -new \
    -key "$TLS_KEY" \
    -subj "/C=AU/O=HashiCorp Sandbox/CN=${WILDCARD_DOMAIN}" \
    -out "$TLS_CSR" 2>/dev/null

  # SAN covers the wildcard (any single-label subdomain) plus the bare apex.
  cat > "$EXT_FILE" <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${WILDCARD_DOMAIN}
DNS.2 = ${TFE_HOSTED_ZONE}
EOF

  log "Signing TLS cert with the sandbox CA..."
  openssl x509 -req \
    -in "$TLS_CSR" \
    -CA "$CA_CERT" \
    -CAkey "$CA_KEY" \
    -CAcreateserial \
    -out "$TLS_CERT" \
    -days 825 \
    -sha256 \
    -extfile "$EXT_FILE" 2>/dev/null

  log "Verifying cert chain..."
  openssl verify -CAfile "$CA_CERT" "$TLS_CERT" >/dev/null
fi

# ---------------------------------------------------------------------------
# base64-encode the PEM files (single line, no wrapping).
# The HVD VM module expects base64-encoded strings for TLS secrets.
# The AKS tfe layer decodes them when creating Kubernetes secrets.
# ---------------------------------------------------------------------------
TLS_CERT_B64="$(base64 < "$TLS_CERT" | tr -d '\n')"
TLS_KEY_B64="$(base64 < "$TLS_KEY"   | tr -d '\n')"
CA_BUNDLE_B64="$(base64 < "$CA_CERT" | tr -d '\n')"

# ---------------------------------------------------------------------------
# Push to Key Vault
# ---------------------------------------------------------------------------
echo
log "=== Creating / updating Key Vault secrets ==="
echo

set_secret "tfe-license"             "$TFE_LICENSE_CONTENT"
set_secret "tfe-encryption-password" "$ENCRYPTION_PASSWORD"
set_secret "tfe-database-password"   "$DB_PASSWORD"
set_secret "tfe-tls-cert"            "$TLS_CERT_B64"
set_secret "tfe-tls-privkey"         "$TLS_KEY_B64"
set_secret "tfe-tls-ca-bundle"       "$CA_BUNDLE_B64"

echo
log "Done. All 6 secrets are in Key Vault '$KEY_VAULT_NAME'."
log "Ensure your Terraform workspaces' run identity has 'Key Vault Secrets User'"
log "role on the vault (or on the subscription) before running terraform apply."
