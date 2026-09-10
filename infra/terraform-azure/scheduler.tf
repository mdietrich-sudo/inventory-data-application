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
    # The function reads both of these; nothing about the schedule is baked into the code.
    TARGET_URL         = local.app_url
    DAILY_RUN_SCHEDULE = local.ncrontab
    WEBSITE_TIME_ZONE  = var.scheduler_time_zone
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
