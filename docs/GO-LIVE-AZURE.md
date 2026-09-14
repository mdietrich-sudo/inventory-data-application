# Go-Live Runbook — Wonder DQ Console (Azure)

**Parallel to [`GO-LIVE.md`](GO-LIVE.md) (GCP) and [`GO-LIVE-AWS.md`](GO-LIVE-AWS.md).** Same app, same
three launch constraints — hosted on Azure instead. Section numbers line up with the other two docs.

> **Read this first — answering the client's two questions.**
>
> **1. Does Azure require significant refactoring? No.** The app is a single container (FastAPI + built
> React) that talks to Postgres, BigQuery, and Jira over their normal client libraries/APIs — nothing in
> the request path is Cloud-Run-specific. There is exactly **one required code change**, already made on
> this branch: the BigQuery client previously relied on GCP's Application Default Credentials (ADC), which
> only exists *inside* GCP (Cloud Run's runtime service account). Azure has no ADC, so
> `wonder/datasource/bigquery.py` now also accepts an explicit service-account key as JSON
> (`GOOGLE_SERVICE_ACCOUNT_JSON`) and falls back to ADC/`GOOGLE_APPLICATION_CREDENTIALS` unchanged — the
> exact shape the client described ("a service account key stored in Key Vault"). Everything else —
> business rules, SQL, the FastAPI routes, the daily-job logic — is unchanged. This is **simpler than the
> AWS path**, which needed Workload Identity Federation to avoid a stored key; Azure's proposal accepts a
> stored key from the start, so there's no cross-cloud trust setup to build.
>
> **2. Does Pavel's team's Azure tenant already have Entra ID SSO? Unconfirmed — needs their answer.**
> If Pavel's team already runs apps behind Entra ID (App Service/Container Apps "Easy Auth" or an App
> Registration), that **can fully replace** the current client-side admin password gate
> (`AdminGate.tsx`, [`wonder-rules-in-code-not-ui`], added in `1ab8c06`, explicitly "not a security
> boundary") with **zero app code** — Easy Auth is a platform feature that sits in front of the container
> and requires no MSAL/JWT-validation code in FastAPI or React. §6 below lays out exactly what to ask
> Pavel's team and what changes once they answer. Until then, this doc (like the GCP/AWS docs) ships
> **no SSO** and treats it as deferred hardening (§10).

Scoped to the **three constraints for this launch**, Azure-flavored:

1. **Hosted on Azure** — single container (FastAPI API + built React app) on **Azure App Service**
   (Linux, Web App for Containers; switched from Container Apps on 2026-09-14 at the client's request),
   app data in **Azure Database for PostgreSQL – Flexible Server**, source data read-only from
   **BigQuery** (unchanged location — the data does not move; see the client's note and confirmed with
   the user: BigQuery stays, only compute/hosting/auth move to Azure).
2. **Linked to the client's real Jira** — not the sandbox `dietrichcoding.atlassian.net`. Identical to
   the GCP/AWS docs — Jira is external SaaS and cloud-agnostic.
3. **No SSO / no permissions for this launch** — public HTTPS endpoint, same posture as the GCP/AWS
   docs, **unless** §6 resolves in Entra ID's favor before go-live, in which case ship with Easy Auth on
   from day one instead of deferring it.

> **Terraform status.** **Written** — [`infra/terraform-azure/`](../infra/terraform-azure/) is the
> `azurerm` port of the GCP module and is `terraform validate`-clean against the provider, but **not yet
> applied** (needs a subscription + credentials). §8 tracks what it contains; its
> [README](../infra/terraform-azure/README.md) has the apply order and the first-apply wrinkles.

---

## Service mapping at a glance (GCP → Azure)

| Concern | GCP (shipped) | Azure (this doc) |
|---|---|---|
| Container runtime | Cloud Run | **Azure App Service** (Linux, Web App for Containers; managed, HTTPS URL). **Chosen over Container Apps at the client's request (2026-09-14)** — their platform team standardizes on App Service. Trade-off: no scale-to-zero (the plan is always allocated), and a **hard, non-configurable ~230s request timeout** — see §7.5 |
| App database | Cloud SQL for Postgres 16 | **Azure Database for PostgreSQL – Flexible Server** |
| Container registry | Artifact Registry | **Azure Container Registry (ACR)** |
| Secrets | Secret Manager | **Azure Key Vault** |
| Runtime identity | Runtime service account | **Managed Identity** (**user-assigned**, shared by the App Service + Function App — see §8.6) — grants Key Vault access, *not* BigQuery access directly |
| Daily run trigger | Cloud Scheduler → `POST /api/run` | **Azure Functions Timer trigger** → `POST /api/run` (per the client's note) |
| **BigQuery read** | **Native SA IAM grant (ADC)** | **Stored service-account key**, held in **Key Vault**, read into `GOOGLE_SERVICE_ACCOUNT_JSON` at container start — no cross-cloud identity federation, per the client's own proposal |
| Auth / SSO | Entra SSO deferred (§10) | **Possibly available now** — Entra ID via Pavel's team's tenant (§6) |
| IaC | Terraform (`google` provider) | Terraform (**`azurerm`** provider) — `infra/terraform-azure/` |

Every row is a like-for-like swap except BigQuery auth, which trades AWS's federation complexity for a
simpler-but-longer-lived credential (a key in Key Vault) — see §10 for the rotation trade-off.

---

## 0. Decisions & access to gather first

- [ ] **Azure subscription + resource group** to deploy into (Pavel's team's environment, per the
      client's note) — confirms this is a *temporary home*, not the permanent one; note that in the
      resource naming/tags so it's easy to tear down or migrate later.
- [ ] **Region** (match whatever region Pavel's team's other apps use, for latency/compliance parity).
- [ ] **BigQuery source projects** (unchanged from GCP/AWS — the data lives in GCP either way):
  - [ ] Ledger/PO dataset project: `wonder-dw-prod-brd` (dataset `inventory`). → `bq_project`.
  - [ ] **ERP standard-cost project**: `wonder-raw-prod` (dataset `erp_prod_batch`) — used by the COST
        rules. Same read-only grant pattern as GCP/AWS, just granted to a **service-account key** instead
        of a runtime SA or federated principal.
  - [ ] **GCP owner/IAM access** to create the read-only service account and its key (or reuse the
        AWS/GCP-side account if one already exists) — this doesn't change with Azure hosting.
- [ ] **Client Jira** (identical to GCP §2 / AWS §2): base URL, project key, issue type, a
      service-account Jira user + API token, and the exact **"Done"** transition name.
- [ ] **Postgres Flexible Server admin password** (you generate; goes into Key Vault, never committed).
- [ ] **Answer to the Entra ID question (§6)** — this changes whether SSO ships at launch or is deferred.
- [ ] **Go-live cutover date** — the day you flip on daily runs and backfill the baseline (same as
      GCP §7 / AWS §7).
- [ ] Who owns the Azure subscription / Terraform state going forward if this becomes more than
      temporary (see §9).

---

## 1. Azure environment foundation

- [ ] **1.1** Confirm you have **Contributor** (or a scoped custom role) on the target resource group in
      Pavel's team's subscription.
- [ ] **1.2** Authenticate locally for Terraform: `az login` (Terraform's `azurerm` provider reads the Az
      CLI context, or use a service principal for CI).
- [ ] **1.3** Register the resource providers Terraform will need if not already registered on the
      subscription: `Microsoft.Web` (App Service **and** Functions), `Microsoft.DBforPostgreSQL`,
      `Microsoft.KeyVault`, `Microsoft.ContainerRegistry`, `Microsoft.OperationalInsights`
      (Log Analytics), `Microsoft.Logic` (only for the Logic App trigger option). `Microsoft.App` is
      **no longer required** — that was Container Apps.
- [ ] **1.4** Decide Terraform **state backend**: an **Azure Storage account + blob container** with
      state locking — **not** local state (contains the DB password and Jira token).
- [ ] **1.5** Confirm whether Pavel's team wants this on their **existing App Service plan** (cheaper if
      they have spare capacity, but the console then shares CPU/memory with their other apps and a
      plan-wide restart hits all of them) or a **dedicated** plan (cleaner blast radius, easier to tear
      down if the app moves to GCP/permanent-Azure later). Given the client called this a possible
      *temporary* home, lean dedicated + easy to delete — the module currently always creates its own
      (`azurerm_service_plan`, default `B1`). Reusing theirs means pointing `service_plan_id` at it;
      the `container_app_environment_id` variable that used to cover this case is **gone**.

## 2. Client Jira setup (replace the sandbox)

**Identical to GCP §2 / AWS §2 — Jira is external SaaS and cloud-agnostic.** In brief:

- [ ] **2.1–2.6** Same six steps as the other two docs: confirm project + key, create a service-account
      Jira user + API token, confirm issue type + a transition named exactly `Done` (or set
      `JIRA_DONE_TRANSITION`), optional fingerprint custom field, map owner groups to real
      assignees/components, and record `jira_base_url` / `jira_email` / `jira_project_key` /
      `jira_issue_type` / `jira_api_token` as Terraform vars/secrets.

## 3. BigQuery read-only access — stored service-account key in Key Vault

**This is the section with no GCP-runbook equivalent**, and it's simpler than the AWS equivalent (§3 of
`GO-LIVE-AWS.md`) because the client's own proposal accepts a stored key rather than asking for
cross-cloud federation.

- [ ] **3.1 (GCP side) Create (or reuse) a read-only service account** in `wonder-dw-prod-brd` (or
      wherever query billing happens), with `roles/bigquery.jobUser` on the billing project and
      `roles/bigquery.dataViewer` on **both** `wonder-dw-prod-brd` (ledger/PO) and `wonder-raw-prod`
      (ERP cost) — the same two grants as GCP §3.1/§3.2, just issued to a **key-based** service account
      instead of the Cloud Run runtime SA.
- [ ] **3.2 (GCP side) Generate a JSON key** for that service account. Treat this as a genuinely
      sensitive, long-lived credential from the moment it's created (see §10 — plan its rotation).
- [ ] **3.3 (Azure side) Store the key in Key Vault** as a secret (e.g. `bq-service-account-json`),
      never in a file committed to the repo or baked into the container image.
- [ ] **3.4 (App config) Wire the secret into the running container as `GOOGLE_SERVICE_ACCOUNT_JSON`.**
      Two ways to do this, in order of preference:
  - **App Service native Key Vault reference** — set the app setting to
    `@Microsoft.KeyVault(SecretUri=...)` and let the platform resolve it (via the app's user-assigned
    managed identity, named in `key_vault_reference_identity_id` and granted `get`/`list` on the
    vault), then map it to the `GOOGLE_SERVICE_ACCOUNT_JSON` env var. No app code needed.
  - Fallback: an init step reads the secret via the SDK and exports it — only needed if the native
    Key Vault references aren't usable (e.g. the identity can't be granted vault access).
- [ ] **3.5** **No further app code change is needed** — `wonder/datasource/bigquery.py` already checks
      `GOOGLE_SERVICE_ACCOUNT_JSON` first and builds explicit `google.oauth2.service_account.Credentials`
      from it (falls back to ADC/`GOOGLE_APPLICATION_CREDENTIALS` if unset, so the *same image* still
      works unmodified on Cloud Run).
- [ ] **3.6** Confirm real table **column names** still match `wonder/schema_map.py` (unchanged — same
      tables, same schema, only the auth path changed).
- [ ] **3.7 Verify end-to-end** from the running App Service before go-live: a BigQuery read
      should succeed using **only** the Key-Vault-sourced key, with no other credential present.

> **Honest trade-off, matching the client's framing:** a stored key is simpler to set up than the AWS
> Workload Identity Federation path, but it is a **long-lived secret that must be rotated** and can be
> used from anywhere if it leaks — WIF's federated tokens are short-lived and cloud-scoped by
> construction. If this Azure hosting becomes permanent rather than temporary, revisit whether Azure
> Workload Identity Federation to GCP is available by then and migrate off the stored key (see §10).

## 4. Build & push the container image (ACR)

- [ ] **4.1** Same image as GCP/AWS — built from `app/Dockerfile`, context `./app`. Push to the **Azure
      Container Registry** Terraform creates.
- [ ] **4.2** Same chicken-and-egg as the other clouds: the App Service needs an image, but the registry
      is created by `apply`. **Option A (recommended):** `terraform apply -target=azurerm_container_registry.app`
      first, then build/push, then full apply.
- [ ] **4.3** Build & push:
      ```bash
      az acr login --name <registry-name>
      docker build -t <registry-name>.azurecr.io/wonder-dq/app:<tag> ./app
      docker push <registry-name>.azurecr.io/wonder-dq/app:<tag>
      ```
- [ ] **4.4** Set `image` in `terraform.tfvars` to that exact tag.

## 5. Configure Terraform variables (public, no SSO — unless §6 says otherwise)

Copy `infra/terraform-azure/terraform.tfvars.example` → `terraform.tfvars`. **Secrets go via env, not
the file.**

- [ ] **5.1** Non-secret vars:
      ```hcl
      subscription_id       = "<pavels-team-subscription-id>"
      resource_group        = "wonder-dq-temp"   # or Pavel's team's naming convention
      create_resource_group = true               # false = reuse their existing RG
      location              = "<match Pavel's team's region>"
      image                 = "<registry-name>.azurecr.io/wonder-dq/app:<tag>"

      daily_run_trigger     = "functions"        # or "logicapp" (zero code) — see §7

      allow_unauthenticated = true          # NO SSO for this launch, unless §6 resolves before go-live

      bq_project            = "wonder-dw-prod-brd"
      erp_bq_project        = "wonder-raw-prod"
      bq_dataset            = "inventory"
      bq_ledger_table       = "consolidated_inventory_ledger"
      bq_po_table           = "int_ledger_purchase_orders"

      jira_base_url         = "https://<client>.atlassian.net"
      jira_email            = "inventory-dq@<client>"
      jira_project_key      = "WIQ"
      jira_issue_type       = "Task"
      ```
- [ ] **5.2** Secrets via environment (never commit):
      ```bash
      export TF_VAR_db_password='<generated-strong-password>'
      export TF_VAR_jira_api_token='<client-jira-api-token>'
      export TF_VAR_google_service_account_json="$(cat readonly-sa-key.json)"
      ```
- [ ] **5.3** Sanity-check: `allow_unauthenticated = true` means the App Service URL is **public**,
      including `POST /api/run` (which creates real Jira tickets). Accept this for the launch or gate it
      (`site_config.ip_restriction` on the App Service, which also covers the SCM/Kudu endpoint) until
      SSO is confirmed/lands. Note an IP allowlist and a cron trigger don't compose — neither
      Functions-on-Consumption nor Logic Apps have stable outbound IPs, so restricting ingress blocks
      the nightly run unless Easy Auth (§6) is doing the authz instead.

## 6. Entra ID SSO — resolve the client's open question before go-live

The client explicitly asked whether Pavel's team's Azure environment already has Entra ID SSO set up,
since that "could solve our authentication gap without extra work on our end." This is worth resolving
*before* go-live because the answer changes §5.3 and removes the client-side password gate entirely
rather than just deferring it again.

- [ ] **6.1** Ask Pavel's team directly: *do other apps in this environment sit behind Entra ID
      (Azure AD) already — e.g. via App Service/Container Apps "Easy Auth," an Application Gateway with
      Entra auth, or a shared App Registration your apps use?*
- [ ] **6.2 If yes:** enable **App Service built-in authentication** (Easy Auth — natively
      Terraformable as `azurerm_linux_web_app_auth_settings_v2`, a smaller lift than the Container Apps
      equivalent) pointed at the same
      Entra tenant/App Registration Pavel's team already uses. This is a **platform-level** feature — no
      MSAL library, no JWT validation code, nothing in FastAPI or React. Once enabled:
  - [ ] Remove/retire `AdminGate.tsx` and `VITE_ADMIN_PASSWORD` (`app/frontend-react/src/AdminGate.tsx`,
        added in `1ab8c06`) — Entra ID becomes the real access boundary instead of a client-side password
        that was explicitly "not a security boundary."
  - [ ] Flip `allow_unauthenticated = false` in Terraform and re-point the Functions Timer trigger's call
        to `POST /api/run` to include whatever auth Easy Auth requires for service-to-service calls (a
        client credential / app role, not a user login).
- [ ] **6.3 If no (or not yet):** ship this launch exactly like the GCP/AWS docs — no SSO, deferred to
      §10 — and keep `AdminGate.tsx` as the (non-security) UI gate in the meantime.
- [ ] **6.4** Either way, note the answer in this doc / a follow-up ticket so the next environment (GCP,
      permanent Azure, or elsewhere) doesn't have to re-ask the same question.

## 7. Daily automation (Azure Functions Timer trigger → `POST /api/run`)

Per the client's own note: adapt the daily job to an **Azure Functions Timer trigger**. Same design as
GCP §7 / AWS §7 — run once a day for the prior data day via an external trigger, **not** the in-app
APScheduler (keep `SCHEDULER_ENABLED=false` so it isn't double-triggered). On Container Apps an
in-process timer was also unreliable because replicas scaled to zero; on App Service with
`always_on = true` it *would* fire, but a single external trigger owner is still the right design —
and §7.5 is the reason the trigger needs to be smarter than one POST.

- [ ] **7.1** Trigger is `POST /api/run` (`wonder/api/routes.py` → `run_daily`) — unchanged, same as
      every other cloud.
- [ ] **7.2** Create a small **Azure Functions app** with a **Timer trigger** (`TimerTrigger` binding,
      cron-style schedule, e.g. `0 15 0 * * *` for 00:15 America/Los\_Angeles — adjust for the Function
      app's configured timezone) whose only job is one `POST <app_service_url>/api/run`. This is
      intentionally the thinnest possible function — a few lines of code — mirroring how Cloud
      Scheduler/EventBridge Scheduler needed *no* app-side function at all; Azure's timer trigger is the
      one piece that needs a tiny deployable, since Azure has no bare "call this URL on a cron" primitive
      outside Logic Apps/Functions. **Written:** the Function App is provisioned by
      `infra/terraform-azure/scheduler.tf` and the function itself is
      `infra/terraform-azure/functions/daily_run/function_app.py` (one timer, one POST, ~40 lines).
      Terraform can't upload function code, so publish it once after `apply`:
      `func azure functionapp publish $(terraform output -raw function_app_name) --python`.
      > **Alternative, also implemented:** set `daily_run_trigger = "logicapp"` for an Azure **Logic
      > App** (Recurrence trigger + HTTP action) instead — same result with zero code and nothing to
      > publish, since Terraform declares the whole workflow. `daily_run_trigger = "none"` provisions
      > no trigger at all.
- [ ] **7.3** No auth this launch (unless §6 resolves to Entra ID, in which case the Function must send
      whatever token Easy Auth requires — a client-credentials app role is the standard pattern).
- [ ] **7.4** The console polls `GET /api/runinfo` and shows a refresh banner when the run date advances
      — no extra wiring, unchanged.

- [ ] **7.5 ⛔ BLOCKER — the ~230s App Service request timeout vs the ~15-minute run.** Introduced by
      the 2026-09-14 move to App Service. App Service's front end **drops any HTTP request that
      produces no response bytes for ~230 seconds, and that limit is not configurable** (Container
      Apps' ingress timeout was). `POST /api/run` blocks for **~15 minutes** — measured by inspection:
      the 2026-09-13 run (403 findings / 307 new / 175 auto-closed) makes **~930 sequential Jira REST
      calls** on one un-pooled `httpx.Client`, which is ~90% of the wall clock. So a **successful** run
      still returns 502 to its caller.
      - **Console button:** not worked around. "Run validation" will error after ~4 minutes while the
        run continues server-side. (The overlay's four-step progress list is cosmetic anyway — a
        1.4s-per-label timer in `App.tsx` that parks on the last label.)
      - **`daily_run_trigger = "functions"`:** worked around. The timer function POSTs, treats a
        gateway timeout as "run started", polls `GET /api/runinfo` until the run date advances, and
        **never raises on timeout** — a raised invocation can be retried by the host, and a retry
        would start a *second concurrent run*. Best-effort only: Consumption caps `functionTimeout`
        at 10 min, under the ~15 min run, so `started but NOT confirmed` is the expected steady state.
      - **`daily_run_trigger = "logicapp"`:** **unusable** until this is fixed — the HTTP action's own
        sync limit (~120s) is tighter still, and `azurerm` exposes neither the timeout nor the
        asynchronous-pattern option.
      - **Fix, in order of preference:**
        1. **Make `POST /api/run` asynchronous** — create the run, return a run id immediately, do the
           work in the background, and let both the console and the trigger poll the existing
           `GET /api/runinfo`. This is the real answer and it fixes the console button too.
        2. **Cut the 15 minutes** (worth doing regardless — see the deferred optimization list in
           `PROCESS.md`): parallelize the Jira calls with a bounded pool (~10x, 15 min → ~90s), cache
           the per-issue `GET /transitions` lookup that `close()` repeats for an identical answer, stop
           commenting "still reproducing" on every open ticket every run, and fire the 18 finder + 18
           recheck BigQuery queries concurrently instead of serially.
        3. **A scheduled App Service WebJob** in the same plan, calling `localhost:8000` — never
           crosses the front end, so the 230s limit doesn't apply at all. This is a genuine upside of
           the App Service move, but `azurerm` has no WebJob resource, so it'd be a deploy-time step.

## 8. Terraform completeness (what `infra/terraform-azure/` must contain)

**Written** in [`infra/terraform-azure/`](../infra/terraform-azure/) (`main.tf`, `scheduler.tf`,
`variables.tf`, `outputs.tf`, `versions.tf`, `terraform.tfvars.example`, `functions/daily_run/`),
`terraform validate`-clean against `azurerm` 4.x. Not yet applied — that needs the subscription from §0.

- [x] **8.1 Resource group** — created, or looked up when `create_resource_group = false`.
- [x] **8.2 Azure Container Registry** (`azurerm_container_registry`, `admin_enabled = false` — pulls
      go through the managed identity's `AcrPull`, no admin user).
- [x] **8.3 Azure Database for PostgreSQL – Flexible Server** + database + the "allow Azure services"
      firewall rule + optional admin IP rules. App Service publishes its outbound IPs (the
      `app_outbound_ips` output) so this *could* be narrowed, but they change on plan scale-up/move;
      public access and single-zone for now, private endpoint/HA deferred to §10.
- [x] **8.4 Key Vault** (RBAC, purge protection off for clean teardown) + secrets `app-db-url`,
      `jira-api-token`, `bq-service-account-json`, and a `Key Vault Secrets User` role assignment for
      the app identity (plus `Secrets Officer` for whoever runs `apply`, since Terraform writes them).
- [x] **8.5 Log Analytics workspace** — always created, plus an `azurerm_monitor_diagnostic_setting` on
      the web app for `AppServiceConsoleLogs` (container stdout), `AppServiceHTTPLogs` and
      `AppServicePlatformLogs` (image pulls / container start failures). Container Apps *required* a
      workspace; App Service doesn't, but without one the only logs are the short-lived filesystem
      stream.
- [x] **8.6 App Service plan + Linux Web App for Containers** (was: Container Apps Environment +
      Container App, until 2026-09-14). Image from ACR pulled with the managed identity, all the env
      vars from the other clouds' container block plus `SCHEDULER_ENABLED=false` and
      `WEBSITES_PORT=8000`, the three secrets as **Key Vault references** by *versionless* URI (so
      rotation needs no Terraform change), `always_on = true`, `health_check_path = /api/health`,
      HTTPS-only, external. Sizing is the plan SKU (`app_service_sku`, default `B1`) +
      `app_service_worker_count` — there is **no scale-to-zero**.
      **Departure:** a **user-assigned** managed identity, not system-assigned. The ACR pull and the
      Key Vault references must be authorized *before* the app is created, and a system-assigned
      principal doesn't exist until *after* — user-assigned breaks that cycle at the same
      least-privilege scope. On App Service it must additionally be named in
      `key_vault_reference_identity_id`, or the platform resolves references with the non-existent
      system-assigned identity and every secret app setting comes back empty.
- [x] **8.7 Function App** (Linux Consumption `Y1`) + storage account + the Timer-trigger function
      from §7 — **or** the Logic App variant, selected by `daily_run_trigger`. The function now
      POSTs-then-polls to survive the §7.5 timeout; the Logic App variant can't and is unusable until
      §7.5 is fixed.
- [x] **8.8 Networking** — public Postgres + public App Service ingress for this launch, with
      `ingress_allowed_ip_ranges` as the interim narrowing knob (`site_config.ip_restriction` +
      `ip_restriction_default_action`, and `scm_use_main_ip_restriction` so Kudu follows the same
      allowlist); private posture stays in §10. A Terraform `check` block warns if
      `allow_unauthenticated = false` is set with an empty allowlist (which would look locked down but
      isn't), and the default action only flips to `Deny` when the allowlist is non-empty so a
      misconfiguration can't lock everyone out.
- [ ] **8.9 Verify auto-close config** against the client's Jira workflow (`JIRA_DONE_TRANSITION`,
      `JIRA_FINGERPRINT_FIELD` — both now Terraform vars) — runtime verification, identical to
      GCP §8.4 / AWS §8.8. Still pending: needs the client's real Jira.

## 9. Migrate off personal / sandbox accounts (before or at go-live)

Same intent as GCP §9 / AWS §9:

- [ ] **9.1 Repo + CI:** move the repo and its CI/CD secrets into the **client's** GitHub org (already
      in progress — see [`wonder-personal-gh-sandbox-migrate`]).
- [ ] **9.2 Jira:** point at the client's Jira (done in §2), not `dietrichcoding.atlassian.net`.
- [ ] **9.3 Azure:** confirm whether Pavel's team's subscription is the **permanent** owner or this is
      genuinely temporary per the client's framing — if temporary, document the planned exit (back to
      GCP, or a later permanent Azure/other environment) so nobody forgets this is provisional.
- [ ] **9.4 GCP:** the read-only BigQuery service account + key (§3) should live under **client-owned**
      GCP identities, not a personal/sandbox project.
- [ ] **9.5 Tokens:** **re-issue every credential** (Jira API token, the BigQuery SA key, any PATs) under
      client-owned identities before this is anything more than a demo.

## 10. Explicitly deferred (post-go-live hardening)

Same trade-offs as GCP §10 / AWS §10, Azure-flavored:

- **Auth / SSO:** resolved (hopefully) by §6. If deferred, the App Service URL is public — anyone with
  it can trigger `POST /api/run` (real Jira tickets). Revisit as soon as §6's answer comes back.
- **BigQuery credential:** a **stored key in Key Vault**, not a federated/short-lived token (the client's
  own proposal, and the simpler path). Put **key rotation** on the follow-up list from day one — this is
  the one place Azure is *less* hardened by default than the AWS-WIF path, and it's worth flagging to the
  client explicitly rather than letting it go unnoticed.
- **Postgres hardening:** the simple posture is sandbox-shaped — public access or a single firewall rule,
  no HA. For prod: private endpoint / VNet integration, zone-redundant HA, automated backups + PITR,
  `deletion_protection`-equivalent settings.
- **Exact breach-age backfill:** unchanged from GCP/AWS — prototype clamps age to ~2 weeks; decide
  backfill depth **X** and pull full per-PO history (bound BigQuery cost).
- **Baseline cutover reseed:** unchanged — at cutover pick the start date and backfill all open
  exceptions as the baseline; defer scope/threshold tuning to then.
- **Observability:** Azure Monitor / Log Analytics alerts on failed runs or anomalous error counts
  (analog of Cloud Logging / CloudWatch).
- **Temporary-home exit plan:** since the client floated Azure as possibly *temporary*, keep the
  Terraform module self-contained enough (§8) that tearing it down or porting it to a permanent
  environment later is a known, bounded amount of work, not a rediscovery project.

## 11. Smoke test (after deploy)

- [ ] **11.1** Open the App Service URL (`terraform output app_url`) — the React console loads.
      `curl $URL/api/health` returns `{"ok":true}` (this is also the platform health-check path).
- [ ] **11.2** `GET <url>/api/runinfo` returns a `runDate`.
- [ ] **11.3** **BigQuery reachability (Azure-specific):** confirm a validation actually reads BigQuery
      using only the Key-Vault-sourced `GOOGLE_SERVICE_ACCOUNT_JSON` — no other credential present on
      the box (§3.7).
- [ ] **11.4** Trigger one `POST <url>/api/run` and confirm the summary (`scanned/seen/new/autoClosed`)
      looks sane.
- [ ] **11.5** Confirm a **real ticket appears in the client's Jira** with the right project/type/assignee,
      and that a resolved item **auto-closes** on the next run.
- [ ] **11.6** Confirm the Azure Functions Timer trigger fires on schedule and advances the run date
      (refresh banner).
- [ ] **11.7** If §6 resolved to Entra ID: confirm an unauthenticated request is rejected and an
      authenticated one succeeds, and that `AdminGate.tsx` has been removed/retired.
