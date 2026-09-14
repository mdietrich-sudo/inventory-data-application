# Daily validation run -> POST <app>/api/run  (docs/GO-LIVE-AZURE.md §7)
#
# Azure has no bare "call this URL on a cron" primitive, so there are two shapes and
# var.daily_run_trigger picks one:
#
#   "functions" (default, the client's proposal) — a Linux Consumption Function App with a single
#       Timer trigger. Terraform provisions the app; the one-file function in ./functions/daily_run
#       is deployed once with `func azure functionapp publish` (see README).
#   "logicapp"  — a Logic App Recurrence trigger + HTTP action. Zero code and fully declarative in
#       Terraform (nothing to deploy afterwards), if the team prefers that.
#
# Both call the same unchanged endpoint. No auth this launch; if §6 resolves to Entra ID, the
# caller must present a client-credentials token (see the note at the bottom of this file).
#
# !! The App Service move (2026-09-14) broke the naive "POST and wait" shape. App Service's front
# end drops a request that sends no response bytes for ~230s and that is not configurable, while
# /api/run blocks for ~15 minutes. So the caller ALWAYS sees a 502 even on a successful run.
#
#   * "functions" handles it: the function POSTs, treats a gateway timeout as "run started" (it
#     did — the work continues server-side), then polls GET /api/runinfo to confirm the run date
#     advanced, and NEVER raises on a timeout. Raising would mark the timer failed and risk a retry
#     firing a second concurrent run, which is worse than an unconfirmed one. Confirmation is
#     best-effort: the Consumption plan caps functionTimeout at 10 min, under the current ~15 min
#     run, so expect "started, not confirmed" in the logs until /api/run goes async.
#   * "logicapp" CANNOT work around it. The HTTP action has its own ~120s sync limit and azurerm
#     exposes neither the timeout nor the asynchronous-pattern option, so this shape reports a
#     failed run every night. Use it only after /api/run returns immediately.
#
# The real fix is app-side: /api/run should create the run, return a run id, and let callers poll
# GET /api/runinfo. Tracked in docs/GO-LIVE-AZURE.md §7.5. App Service also unlocks a cleaner
# option than either of these — a scheduled **WebJob** in the same plan calls localhost:8000 and
# never touches the front end, so the 230s limit doesn't apply at all; azurerm has no WebJob
# resource, so it would be a deploy-time step rather than Terraform.

locals {
  run_uri = "${local.app_url}/api/run"

  # Functions NCRONTAB is 6-field (seconds first); Logic Apps take hour/minute lists.
  ncrontab = "0 ${var.scheduler_minute} ${var.scheduler_hour} * * *"

  use_functions = var.daily_run_trigger == "functions"
  use_logicapp  = var.daily_run_trigger == "logicapp"
}

# ---------------------------------------------------------------------------
# Option A: Azure Functions Timer trigger
# ---------------------------------------------------------------------------

# Functions requires a storage account for its own bookkeeping (timer leases, host state).
resource "azurerm_storage_account" "fn" {
  count                    = local.use_functions ? 1 : 0
  name                     = local.storage_name
  resource_group_name      = local.rg_name
  location                 = local.rg_location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"
  tags                     = var.tags
}

resource "azurerm_service_plan" "fn" {
  count               = local.use_functions ? 1 : 0
  name                = "${var.service_name}-fn-plan"
  resource_group_name = local.rg_name
  location            = local.rg_location
  os_type             = "Linux"
  sku_name            = "Y1" # Consumption
  tags                = var.tags
}

resource "azurerm_linux_function_app" "daily_run" {
  count                       = local.use_functions ? 1 : 0
  name                        = "${var.service_name}-daily-run-${local.suffix}"
  resource_group_name         = local.rg_name
  location                    = local.rg_location
  service_plan_id             = azurerm_service_plan.fn[0].id
  storage_account_name        = azurerm_storage_account.fn[0].name
  storage_account_access_key  = azurerm_storage_account.fn[0].primary_access_key
  functions_extension_version = "~4"
  https_only                  = true
  tags                        = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  site_config {
    application_stack {
      python_version = var.function_python_version
    }
  }

  app_settings = {
    FUNCTIONS_WORKER_RUNTIME = "python"
    # Required for the Python v2 programming model used by ./functions/daily_run.
    AzureWebJobsFeatureFlags = "EnableWorkerIndexing"
    # The function reads these; nothing about the schedule or the URL is baked into the code.
    TARGET_URL         = local.app_url
    DAILY_RUN_SCHEDULE = local.ncrontab
    WEBSITE_TIME_ZONE  = var.scheduler_time_zone
    # How long to keep polling GET /api/runinfo for confirmation after the POST is cut off by the
    # App Service front end. Must stay under host.json's functionTimeout (10 min on Consumption).
    DAILY_RUN_POLL_BUDGET_SECONDS = tostring(var.daily_run_poll_budget_seconds)
  }

  lifecycle {
    # `func azure functionapp publish` sets this when it uploads the package; don't revert it.
    ignore_changes = [app_settings["WEBSITE_RUN_FROM_PACKAGE"]]
  }
}

# ---------------------------------------------------------------------------
# Option B: Logic App (Recurrence -> HTTP POST). No code to deploy.
# ---------------------------------------------------------------------------

resource "azurerm_logic_app_workflow" "daily_run" {
  count               = local.use_logicapp ? 1 : 0
  name                = "${var.service_name}-daily-run"
  resource_group_name = local.rg_name
  location            = local.rg_location
  tags                = var.tags
}

resource "azurerm_logic_app_trigger_recurrence" "daily" {
  count        = local.use_logicapp ? 1 : 0
  name         = "daily"
  logic_app_id = azurerm_logic_app_workflow.daily_run[0].id
  frequency    = "Day"
  interval     = 1
  # Logic Apps use Windows time-zone names, not IANA — hence the separate variable.
  time_zone = var.scheduler_time_zone_windows

  schedule {
    at_these_hours   = [var.scheduler_hour]
    at_these_minutes = [var.scheduler_minute]
  }
}

# NOTE: see the header — this shape will report a failed run every night while /api/run blocks for
# ~15 min, because the HTTP action's own sync limit (~120s) is even tighter than App Service's 230s.
resource "azurerm_logic_app_action_http" "post_run" {
  count        = local.use_logicapp ? 1 : 0
  name         = "post-api-run"
  logic_app_id = azurerm_logic_app_workflow.daily_run[0].id
  method       = "POST"
  uri          = local.run_uri

  headers = {
    "Content-Type" = "application/json"
  }

  depends_on = [azurerm_logic_app_trigger_recurrence.daily]
}

# NOTE (§6/§7.3): both options call /api/run unauthenticated, which is only acceptable while the
# console itself is unauthenticated. When Entra ID Easy Auth is enabled:
#   - functions: have the function fetch a token for the app registration via its managed identity
#                (client-credentials / app role) and send it as a Bearer header;
#   - logicapp:  add an "Authentication" block of type ManagedServiceIdentity to the HTTP action;
#   - and add the trigger's principal to var.ingress_allowed_ip_ranges' replacement (Easy Auth
#     handles the authz, so the IP allowlist can go away).
# On App Service, Easy Auth is azurerm_linux_web_app_auth_settings_v2 — a native resource, so this
# is a smaller lift than it was on Container Apps.
#
# Either trigger also has to be reachable: when allow_unauthenticated=false the IP allowlist on the
# App Service applies to the trigger too, and neither Functions-on-Consumption nor Logic Apps have
# stable outbound IPs. Entra ID Easy Auth (above) is the answer; an IP allowlist and a cron trigger
# do not compose.
