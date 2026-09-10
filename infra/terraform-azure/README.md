# Wonder DQ — infrastructure (Terraform, **Azure**)

Azure port of [`../terraform`](../terraform) (GCP Cloud Run). Provisions the console on Azure:
**Container Apps** (the container from `app/Dockerfile`), **Azure Database for PostgreSQL –
Flexible Server** (the app DB), **Key Vault** (DB URL + Jira token + the BigQuery SA key), **Azure
Container Registry**, a least-privilege **user-assigned managed identity**, a **Log Analytics
workspace**, and the nightly **`POST /api/run`** trigger.

Design, decisions and the full task list: **[`../../docs/GO-LIVE-AZURE.md`](../../docs/GO-LIVE-AZURE.md)** —
section references below point there.

> Status: **scaffold**, `terraform validate`-clean against the `azurerm` provider but **not yet
> applied** — it needs a subscription + credentials. Source data stays in **BigQuery**; only
> compute/hosting/auth move to Azure.

## What differs from the GCP module

| Concern | GCP | Azure (here) |
|---|---|---|
| Container runtime | Cloud Run | `azurerm_container_app` (+ environment, Log Analytics) |
| App DB | Cloud SQL Postgres 16, unix socket | Flexible Server Postgres 16, TCP + `sslmode=require` |
| Registry | Artifact Registry | ACR (`admin_enabled = false`; pulls via managed identity) |
| Secrets | Secret Manager | Key Vault (RBAC), referenced by Container Apps secrets |
| Runtime identity | Runtime service account | **User-assigned** managed identity (see note below) |
| BigQuery auth | ADC via the runtime SA | **SA key JSON in Key Vault** → `GOOGLE_SERVICE_ACCOUNT_JSON` (§3) |
| Nightly run | Cloud Scheduler → `/api/run` | Functions Timer trigger **or** Logic App → `/api/run` (§7) |

Two deliberate departures from the sketch in `GO-LIVE-AZURE.md` §8:

- **User-assigned identity, not system-assigned.** The Container App's Key Vault secret references
  and its ACR pull must be authorized *before* the app is created; a system-assigned principal only
  exists *after* creation, so that ordering is impossible. A user-assigned identity created up front
  breaks the cycle — same least-privilege posture (`AcrPull` + `Key Vault Secrets User`, nothing else).
- **The Logic App option is implemented too.** §7.2 listed it as an alternative; it costs ~30 lines
  and is fully declarative (no code to publish), so `daily_run_trigger` selects either shape.

## Prerequisites

- `terraform >= 1.5`
- `az login` (the `azurerm` provider uses the Az CLI context; use a service principal in CI)
- **Contributor** on the target resource group, plus rights to create role assignments
  (Contributor alone cannot — you need **User Access Administrator**/**Owner**, or have someone
  pre-create the three `azurerm_role_assignment`s and import them). §1.1
- Resource providers registered on the subscription (§1.3): `Microsoft.App`,
  `Microsoft.DBforPostgreSQL`, `Microsoft.KeyVault`, `Microsoft.ContainerRegistry`,
  `Microsoft.OperationalInsights`, `Microsoft.Web` (Functions), `Microsoft.Logic` (Logic App option).
- `func` (Azure Functions Core Tools) only if `daily_run_trigger = "functions"`.

## Deploy

```bash
cd infra/terraform-azure
cp terraform.tfvars.example terraform.tfvars     # fill in non-secret values

# 1. Secrets via env (never commit them):
export TF_VAR_db_password='<generated-strong-password>'
export TF_VAR_jira_api_token='<client-jira-api-token>'
export TF_VAR_google_service_account_json="$(cat readonly-sa-key.json)"   # §3.2

terraform init
terraform validate

# 2. Registry first — Container Apps needs an image that doesn't exist yet (§4.2):
terraform apply -target=azurerm_container_registry.app

# 3. Build + push the image, then set `image` in terraform.tfvars to that exact tag:
ACR=$(terraform output -raw acr_name)
az acr login --name "$ACR"
docker build -t "$(terraform output -raw image_repository):v1" ../../app
docker push "$(terraform output -raw image_repository):v1"

# 4. Everything else:
terraform apply

# 5. Only if daily_run_trigger = "functions" — publish the one-file timer app (§7.2):
func azure functionapp publish "$(terraform output -raw function_app_name)" --python
```

`terraform output app_url` prints the console URL. The container runs `alembic upgrade head` on
start, so the Postgres schema is provisioned automatically.

### Known first-apply wrinkles

- **Key Vault 403 on the first run.** The vault uses RBAC, and Azure role assignments are
  eventually consistent — the `Key Vault Secrets Officer` grant Terraform just created may not be
  visible yet when it writes the three secrets. Re-run `terraform apply`; it succeeds on the second
  pass. (Nothing is left half-created.)
- **`image` must exist before step 4**, or the Container App revision fails to activate.
- **ACR/Key Vault/storage names are globally unique** and get a random 4-char suffix. Pin
  `name_suffix` in tfvars if you want them stable across a state rebuild.

## Verify (§11)

```bash
URL=$(terraform output -raw app_url)
curl -s "$URL/api/runinfo"          # returns a runDate
curl -s -X POST "$URL/api/run"      # real Jira tickets — see the warning below
```

§11.3 is the Azure-specific one: confirm a validation actually **reads BigQuery using only the
Key-Vault-sourced key**, with no other credential on the box.

## Notes / go-live hardening (§10)

- **State holds secrets** — the DB password, the Jira token and the BigQuery SA key all flow into
  state. Use the `azurerm` blob backend in `versions.tf` (encrypted, access-controlled, locking),
  not local state. §1.4
- **No SSO this launch.** `allow_unauthenticated = true` leaves the URL public, including
  `POST /api/run` (which creates real Jira tickets). `allow_unauthenticated = false` only narrows
  ingress to `ingress_allowed_ip_ranges` — it is **not** authentication. Real auth = **Entra ID
  Easy Auth**, which is a platform feature needing no app code; that's blocked on the client's
  answer in §6, and when it lands `AdminGate.tsx` / `VITE_ADMIN_PASSWORD` can be retired.
- **The BigQuery SA key is long-lived.** This is the one place Azure is less hardened than the AWS
  WIF path. Put rotation on the follow-up list from day one; re-issue it under client-owned GCP
  identities (§9.4/§9.5). Rotating it is a Key Vault secret update — the Container App resolves
  `bq-service-account-json` by *versionless* ID, so a new revision picks it up with no Terraform change.
- **Postgres is sandbox-shaped**: public network access with the "allow Azure services" rule, single
  zone, 7-day backups. Prod: private endpoint / VNet integration, zone-redundant HA, PITR.
- **This may be a temporary home** (§9.3). Everything is tagged `lifecycle = temporary`, the vault
  has purge protection off, and `create_resource_group = true` keeps the blast radius to one RG —
  `terraform destroy` should genuinely clean up.
