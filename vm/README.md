# Terraform Enterprise on Azure VM

Deploys HashiCorp Terraform Enterprise (TFE) on Azure Virtual Machines using the [terraform-enterprise-hvd/azurerm](https://registry.terraform.io/modules/hashicorp/terraform-enterprise-hvd/azurerm/latest) HVD module (version `1.0.0`).

State is managed remotely via HCP Terraform (`jaz-hashi` org, workspace `tfe-hvd-azure-vm`).

**Why a single workspace** (vs the three-layer split in `aks/`): everything here is plain Azure infrastructure with no Kubernetes provider in the loop — the HVD module boots TFE via cloud-init (custom_data), and DNS/TLS/secrets are all resolvable at plan time. There is no "depends on the running cluster" middle layer to isolate, so one state and one apply is the simplest correct shape.

---

## Overview

| Component | Detail |
|---|---|
| Region | `australiaeast` (configurable via `location` variable) |
| VM runtime | Azure Virtual Machine Scale Set (VMSS) |
| Load Balancer | Internet-facing Azure Load Balancer, restricted by a VM-subnet NSG |
| Database | Azure Database for PostgreSQL Flexible Server |
| Cache | Azure Cache for Redis (Premium) |
| Object Storage | Azure Blob Storage (Storage Account) |
| DNS | Azure DNS public zone (A record created by the module) |
| VNet CIDR | `10.1.0.0/16` |
| Secrets | Azure Key Vault |
| State backend | HCP Terraform (`tfe-hvd-azure-vm`) |

---

## Prerequisites

- Terraform >= 1.9
- Azure CLI, `openssl`, and `jq` (see the root preflight)
- HCP Terraform access to the `jaz-hashi` organization and `tfe-hvd-azure-vm` workspace
- The Entra ID application with federated credentials for HCP TF dynamic credentials (see [root README](../README.md))
- Secrets pre-created in Azure Key Vault via [`../scripts/create_tfe_secrets.sh`](../scripts/): license, encryption password, database password, and TLS certificate / private key / CA bundle
- An existing Azure DNS public zone for the target domain
- The Entra app must have **Key Vault Secrets User** role on the Key Vault
- A valid OpenSSH public key. The configuration does not open SSH to the internet; use Azure Bastion, VPN/ExpressRoute, or a private jump host.
- An explicit `allowed_ingress_cidrs` list covering users and every VCS/CI/agent system that must call TFE. Do not use `0.0.0.0/0` outside a disposable sandbox.

## Security posture and limits

- Public HTTPS is allowlisted by an NSG on the VM subnet. Azure Load Balancer health probes and VNet-internal traffic remain covered by Azure's default NSG rules.
- TLS enforcement, HSTS/secure cookies, boot diagnostics, Blob versioning, and Blob change feed are enabled.
- PostgreSQL, Redis, and Blob Storage use private endpoints by module default. Storage public network access remains enabled for initial provisioning, but its firewall defaults to deny and allows the VM subnet/Azure services.
- The module defaults to one TFE VM and PostgreSQL without zone-redundant HA. This is sandbox/demo availability, not production HA.
- PostgreSQL backup retention defaults to 35 days and geo-redundant backup is enabled by the module. Those backups are not a tested disaster-recovery plan; restore procedures and RTO/RPO still need to be exercised.
- No Log Analytics destination or alerting is configured. Enable module log forwarding, metrics collection, Azure Monitor alerts, Defender for Cloud, and diagnostic settings before treating this as production.
- HCP Terraform state contains sensitive resource metadata and references to Key Vault secrets. Limit workspace/state access even though secret values are not copied into root outputs.

---

## Usage

Run all commands from this `vm/` directory.

```sh
terraform login   # first time only
terraform init
terraform plan
terraform apply
```

The workspace is CLI-driven: the `cloud {}` block in [provider.tf](provider.tf) points runs at `tfe-hvd-azure-vm`, and authentication to Azure uses HCP TF dynamic credentials (no static keys).

---

## First-time setup: initial admin user

After the apply completes and TFE is healthy (the cloud-init logs show `[INFO] TFE custom_data script finished successfully!`), create the first admin user with the Initial Admin Creation Token (IACT).

1. Connect to a VM in the VMSS over a private path using the SSH key set in `vm_ssh_public_key`:

   ```sh
   ssh tfeadmin@<vm-private-ip>
   ```

2. On the VM, check TFE health and retrieve the IACT:

   ```sh
   cd /etc/tfe
   sudo docker compose exec tfe tfe-health-check-status
   sudo docker compose exec tfe tfectl admin token
   ```

3. Create the admin user by opening in a browser:

   ```
   https://<tfe_fqdn>/admin/account/new?token=<TOKEN>
   ```

Notes:
- The IACT is time-bounded (default 60 minutes after startup) and single-use. After the first admin user is created, the token is invalid permanently.
- See the [initial admin user docs](https://developer.hashicorp.com/terraform/enterprise/flexible-deployments/install/initial-admin-user) for API and other methods.

---

## Variables

| Name | Type | Required | Description |
|---|---|---|---|
| `friendly_name_prefix` | `string` | yes | 1-17 lowercase alphanumeric characters, no hyphens; must differ from AKS |
| `tfe_fqdn` | `string` | yes | FQDN for the TFE instance (e.g. `tfe-vm.example.com`). Must differ from the AKS deployment. |
| `dns_zone_name` | `string` | yes | Azure DNS public zone name (e.g. `example.com`) |
| `dns_zone_rg_name` | `string` | yes | Resource Group where the DNS zone resides |
| `key_vault_name` | `string` | yes | Name of the Azure Key Vault holding TFE secrets (≤ 24 chars, globally unique) |
| `key_vault_rg_name` | `string` | yes | Resource Group where the Key Vault resides |
| `location` | `string` | no | Azure region (default `australiaeast`) |
| `container_runtime` | `string` | no | `docker` or `podman` (default `docker`) |
| `tfe_image_tag` | `string` | no | pinned TFE image (default `v202505-1`); review mandatory upgrade hops before changing |
| `allowed_ingress_cidrs` | `list(string)` | yes | public source CIDRs allowed to reach TFE HTTPS |
| `vm_ssh_public_key` | `string` | yes | OpenSSH public key for private/Bastion VM administration |
| `tags` | `map(string)` | no | Additional tags applied to all Azure resources |

TFE secrets (license, encryption password, database password, TLS cert/key/CA bundle) are looked up by name from `key_vault_name` in [data.tf](data.tf) — no secret IDs are ever workspace variables.

---

## Outputs

| Name | Description |
|---|---|
| `tfe_url` | HTTPS URL of the TFE instance |
| `resource_group_name` | Azure Resource Group name |
| `vnet_id` | VNet ID |
| `vm_subnet_id` | VM subnet ID |
| `db_subnet_id` | Database subnet ID |
| `redis_subnet_id` | Redis subnet ID |

---

## Module Sources

| Module | Source | Version |
|---|---|---|
| `tfe_hvd` | [hashicorp/terraform-enterprise-hvd/azurerm](https://registry.terraform.io/modules/hashicorp/terraform-enterprise-hvd/azurerm/1.0.0) | `1.0.0` |
