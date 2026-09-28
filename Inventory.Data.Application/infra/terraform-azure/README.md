# Wonder DQ — infrastructure (Terraform, **Azure**)

Azure port of [`../terraform`](../terraform) (GCP Cloud Run). Provisions the console on Azure:
**App Service** (Linux Web App for Containers, running the image from `app/Dockerfile`), **Azure
Database for PostgreSQL – Flexible Server** (the app DB), **Key Vault** (DB URL + Jira token + the
BigQuery SA key), **Azure Container Registry**, a least-privilege **user-assigned managed
identity**, a **Log Analytics workspace**, and the nightly **`POST /api/run`** trigger.

> **Hosting is App Service, switched from Container Apps on 2026-09-14 at the client's request**
> (their platform team standardizes on App Service). See [What the switch
> changed](#what-the-switch-from-container-apps-changed) — one item in there is a **deploy
> blocker**, not a cosmetic difference.

Design, decisions and the full task list: **[`../../docs/GO-LIVE-AZURE.md`](../../docs/GO-LIVE-AZURE.md)** —
section references below point there.

> Status: **scaffold**, `terraform validate`-clean against `azurerm` 4.81 but **not yet
> applied** — it needs a subscription + credentials. Source data stays in **BigQuery**; only
> compute/hosting/auth move to Azure.

## What differs from the GCP module

| Concern | GCP | Azure (here) |
|---|---|---|
| Container runtime | Cloud Run | `azurerm_linux_web_app` on `azurerm_service_plan` (App Service for Containers) |
| App DB | Cloud SQL Postgres 16, unix socket | Flexible Server Postgres 16, TCP + `sslmode=require` |
| Registry | Artifact Registry | ACR (`admin_enabled = false`; pulls via managed identity) |
| Secrets | Secret Manager | Key Vault (RBAC), read via App Service **Key Vault references** |
| Runtime identity | Runtime service account | **User-assigned** managed identity (see note below) |
| BigQuery auth | ADC via the runtime SA | **SA key JSON in Key Vault** → `GOOGLE_SERVICE_ACCOUNT_JSON` (§3) |
| Nightly run | Cloud Scheduler → `/api/run` | Functions Timer trigger **or** Logic App → `/api/run` (§7) |
| Scale to zero | Cloud Run min-instances 0 | **Not available** — the App Service plan is always allocated |

Two deliberate departures from the sketch in `GO-LIVE-AZURE.md` §8:

- **User-assigned identity, not system-assigned.** The app's Key Vault references and its ACR pull
  must be authorized *before* the app is created; a system-assigned principal only exists *after*
  creation, so that ordering is impossible. A user-assigned identity created up front breaks the
  cycle — same least-privilege posture (`AcrPull` + `Key Vault Secrets User`, nothing else). On
  App Service this identity must also be named in `key_vault_reference_identity_id`, or the
  platform tries to resolve secrets with the (non-existent) system-assigned identity and every
  secret app setting silently comes back empty.
- **The Logic App option is implemented too.** §7.2 listed it as an alternative; it costs ~30 lines
  and is fully declarative (no code to publish), so `daily_run_trigger` selects either shape. It is
  **not usable today** — see the blocker below.

## What the switch from Container Apps changed

| Concern | Container Apps (before) | App Service (now) |
|---|---|---|
| Compute | `azurerm_container_app` + `azurerm_container_app_environment` | `azurerm_linux_web_app` + `azurerm_service_plan` (`os_type = "Linux"`) |
| Sizing | `min_replicas`/`max_replicas`, `container_cpu`, `container_memory` | `app_service_sku`, `app_service_worker_count`, `always_on` |
| Scale to zero | Yes (`min_replicas = 0`) | **No** — plan is always allocated. No cold-start `alembic upgrade head`, but no idle savings either |
| Secrets | `secret {}` blocks + `env { secret_name }` | `@Microsoft.KeyVault(SecretUri=...)` in `app_settings` + `key_vault_reference_identity_id` |
| Port | `ingress { target_port = 8000 }` | `WEBSITES_PORT = "8000"` app setting (App Service also injects `$PORT`, which the Dockerfile CMD honours) |
| IP allowlist | `ingress { ip_security_restriction {} }` | `site_config { ip_restriction {} }` + an explicit `ip_restriction_default_action`, and `scm_use_main_ip_restriction` for Kudu |
| Registry auth | `registry { identity }` | `container_registry_use_managed_identity` + `container_registry_managed_identity_client_id` |
| Image reference | one fully-qualified string | registry URL and `repo:tag` split apart (`var.image` is still one string; `main.tf` splits it) |
| Hostname | unique per environment | **globally** unique (`<name>.azurewebsites.net`) — hence the mandatory `name_suffix` |
| Logs | Log Analytics, required by the environment | Log Analytics is optional; kept + wired via `azurerm_monitor_diagnostic_setting` |
| Health check | — | `health_check_path = "/api/health"` (dependency-free 200; deliberately *not* `/api/runinfo`, which hits the DB) |
| Easy Auth (§6) | awkward | native `azurerm_linux_web_app_auth_settings_v2` — a smaller lift when §6 resolves |
| Reused shared env | `container_app_environment_id` var | **removed** — no equivalent; the plan is cheap and dedicated |

### ⛔ Deploy blocker introduced by the switch

App Service's front end **drops any HTTP request that produces no response bytes for ~230 seconds,
and that limit is not configurable** (Container Apps' ingress timeout was). `POST /api/run`
currently blocks for **~15 minutes** — ~930 serial Jira REST calls — so **both the console's
"Run validation" button and the nightly trigger will see a 502 even when the run succeeds.**

- **`daily_run_trigger = "functions"` works around it.** The timer function POSTs, treats a gateway
  timeout as "run started" (it did — the work continues server-side), then polls `GET /api/runinfo`
  to confirm the run date advanced, and **never raises on a timeout** (a raised invocation can be
  retried by the host, and a retry would start a *second concurrent run*). Confirmation is
  best-effort: the Consumption plan caps `functionTimeout` at 10 minutes, under the ~15 minute run,
  so `started but NOT confirmed` is the expected log line until the app side is fixed.
- **`daily_run_trigger = "logicapp"` does not work.** The HTTP action's own sync limit (~120s) is
  tighter still, and `azurerm` exposes neither the timeout nor the asynchronous-pattern option.
- **The console button is not worked around at all** and will show an error after ~4 minutes.

**The actual fix is app-side**: `POST /api/run` should create the run, return a run id immediately,
and let callers poll the existing `GET /api/runinfo`. Tracked in `GO-LIVE-AZURE.md` §7.5, along with
the run-time optimizations that would bring 15 min down to ~90s regardless of platform. App Service
also unlocks a cleaner trigger than either option above — a scheduled **WebJob** in the same plan
calls `localhost:8000` and never crosses the front end, so the 230s limit doesn't apply; `azurerm`
has no WebJob resource, so that would be a deploy-time step rather than Terraform.

## Prerequisites

- `terraform >= 1.5`
- `az login` (the `azurerm` provider uses the Az CLI context; use a service principal in CI)
- **Contributor** on the target resource group, plus rights to create role assignments
  (Contributor alone cannot — you need **User Access Administrator**/**Owner**, or have someone
  pre-create the three `azurerm_role_assignment`s and import them). §1.1
- Resource providers registered on the subscription (§1.3): `Microsoft.Web` (App Service **and**
  Functions), `Microsoft.DBforPostgreSQL`, `Microsoft.KeyVault`, `Microsoft.ContainerRegistry`,
  `Microsoft.OperationalInsights`, `Microsoft.Logic` (Logic App option). `Microsoft.App` is **no
  longer needed** — that was Container Apps.
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

# 2. Registry first — the App Service needs an image that doesn't exist yet (§4.2):
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

`terraform output app_url` prints the console URL (`https://<service_name>-<suffix>.azurewebsites.net`).
The container runs `alembic upgrade head` on start, so the Postgres schema is provisioned
automatically — and with `always_on = true` that happens once at deploy rather than on a user's
first request.

### Known first-apply wrinkles

- **Key Vault 403 on the first run.** The vault uses RBAC, and Azure role assignments are
  eventually consistent — the `Key Vault Secrets Officer` grant Terraform just created may not be
  visible yet when it writes the three secrets. Re-run `terraform apply`; it succeeds on the second
  pass. (Nothing is left half-created.)
- **`image` must exist before step 4**, or the web app starts, fails to pull, and sits in a
  restart loop. `az webapp log tail --name $(terraform output -raw app_service_name)` shows the
  pull error; the `AppServicePlatformLogs` category in Log Analytics keeps it.
- **ACR/Key Vault/storage/web-app names are globally unique** and get a random 4-char suffix. Pin
  `name_suffix` in tfvars if you want them stable across a state rebuild — note the web app's
  *hostname* depends on it, so changing it changes `app_url`.
- **Empty secret app settings = a Key Vault reference that didn't resolve.** Check
  `key_vault_reference_identity_id` points at the user-assigned identity and that its
  `Key Vault Secrets User` assignment has propagated; the portal's app-settings blade shows a green
  check per resolved reference.

## Verify (§11)

```bash
URL=$(terraform output -raw app_url)
curl -s "$URL/api/health"           # {"ok":true} — also the App Service health-check path
curl -s "$URL/api/runinfo"          # returns a runDate
curl -s -X POST "$URL/api/run"      # real Jira tickets — and see the blocker above: this returns
                                    # 502 after ~230s while the run keeps going server-side
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
  identities (§9.4/§9.5). Rotating it is a Key Vault secret update — the app references
  `bq-service-account-json` by *versionless* URI, so App Service picks up the new value on its next
  refresh (or immediately on `az webapp restart`) with no Terraform change.
- **Postgres is sandbox-shaped**: public network access with the "allow Azure services" rule, single
  zone, 7-day backups. Prod: private endpoint / VNet integration, zone-redundant HA, PITR. App
  Service *does* publish stable-ish outbound IPs (`terraform output app_outbound_ips`) so the
  firewall could be narrowed to those — but they change on plan scale-up/move, which would silently
  break the DB connection. VNet integration needs a P-tier SKU.
- **This may be a temporary home** (§9.3). Everything is tagged `lifecycle = temporary`, the vault
  has purge protection off, and `create_resource_group = true` keeps the blast radius to one RG —
  `terraform destroy` should genuinely clean up.
