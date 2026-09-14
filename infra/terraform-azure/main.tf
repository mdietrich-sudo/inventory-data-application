# Wonder DQ console on Azure — App Service (Linux, container) + PostgreSQL Flexible Server +
# Key Vault + ACR. Azure port of infra/terraform (GCP Cloud Run). Design + task list:
# docs/GO-LIVE-AZURE.md §8.
#
# Hosting is **App Service**, switched from Container Apps on 2026-09-14 at the client's request
# (their platform team standardizes on App Service). What that changed, and why it matters:
#   * Container Apps Environment + Container App  ->  azurerm_service_plan + azurerm_linux_web_app.
#   * Container Apps `secret` blocks             ->  App Service **Key Vault references**
#     (`@Microsoft.KeyVault(SecretUri=...)`) in app_settings, resolved by the identity named in
#     `key_vault_reference_identity_id`. Still versionless, so rotation needs no Terraform change.
#   * `ingress { target_port = 8000 }`            ->  `WEBSITES_PORT` app setting.
#   * min/max_replicas + per-container cpu/memory ->  the service plan's SKU + `always_on`. There is
#     no scale-to-zero on App Service: the plan is always allocated (so no cold-start
#     `alembic upgrade head`, but also no scale-to-zero savings).
#
# !! DEPLOY BLOCKER — read before applying. App Service's front end drops any HTTP request that
# produces no response bytes for ~230s, and that limit is NOT configurable (Container Apps' ingress
# timeout was). `POST /api/run` currently blocks for ~15 minutes (~930 serial Jira calls), so both
# the console button and the nightly trigger will see a 502 even though the run keeps going
# server-side. `/api/run` must become fire-and-forget (return a run id, poll the existing
# GET /api/runinfo) before this module is useful in production. scheduler.tf works around the
# symptom for the nightly run only. See docs/GO-LIVE-AZURE.md §7.5.
#
# What differs from the GCP module, and why:
#   * BigQuery source data does NOT move. Azure has no GCP ADC, so instead of a runtime service
#     account IAM grant, a read-only SA *key* lives in Key Vault and is referenced into the app as
#     GOOGLE_SERVICE_ACCOUNT_JSON (already supported by wonder/datasource/bigquery.py). §3.
#   * Identity is a USER-ASSIGNED managed identity, not system-assigned as §8.6 first sketched: the
#     app's Key Vault references and its ACR pull must be authorized *before* the app is created,
#     which is impossible with a system-assigned principal that only exists after creation.
#     User-assigned breaks that cycle and is the standard pattern here.

data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 4
  special = false
  upper   = false
}

locals {
  suffix = coalesce(var.name_suffix, random_string.suffix.result)

  # Globally-unique, charset-constrained names.
  acr_name     = substr(replace("${var.service_name}${local.suffix}", "-", ""), 0, 50) # alphanumeric only
  kv_name      = substr("${var.service_name}-kv-${local.suffix}", 0, 24)               # <= 24 chars
  storage_name = substr(lower(replace("${var.service_name}fn${local.suffix}", "-", "")), 0, 24)

  # App Service hostnames are globally unique (<name>.azurewebsites.net), so unlike the Container
  # App — which only had to be unique inside its environment — the suffix is mandatory here.
  web_app_name = substr("${var.service_name}-${local.suffix}", 0, 60)

  rg_name     = var.create_resource_group ? azurerm_resource_group.rg[0].name : data.azurerm_resource_group.existing[0].name
  rg_location = var.create_resource_group ? azurerm_resource_group.rg[0].location : data.azurerm_resource_group.existing[0].location

  # App Service wants the registry URL and the repository:tag as two fields, where Container Apps
  # took one fully-qualified reference. Keep var.image as the full reference (tfvars and the README
  # build/push flow are unchanged) and split it here.
  image_parts    = split("/", var.image)
  image_registry = local.image_parts[0]
  image_repo_tag = join("/", slice(local.image_parts, 1, length(local.image_parts)))

  # The app reads a single APP_DB_URL. Flexible Server is a real TCP host (no unix socket like
  # Cloud SQL), and it requires TLS — hence sslmode=require.
  app_db_url = "postgresql+psycopg://${var.db_user}:${urlencode(var.db_password)}@${azurerm_postgresql_flexible_server.pg.fqdn}:5432/${var.db_name}?sslmode=require"

  # App Service Key Vault references. Versionless URIs so rotating a secret is a Key Vault update
  # with no Terraform change (App Service re-resolves them periodically, and on restart).
  kv_refs = {
    APP_DB_URL                  = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.app_db_url.versionless_id})"
    JIRA_API_TOKEN              = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.jira_api_token.versionless_id})"
    GOOGLE_SERVICE_ACCOUNT_JSON = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.bq_service_account_json.versionless_id})"
  }

  app_url = "https://${azurerm_linux_web_app.app.default_hostname}"
}

# --- Resource group (create, or reuse the client's) ---
resource "azurerm_resource_group" "rg" {
  count    = var.create_resource_group ? 1 : 0
  name     = var.resource_group
  location = var.location
  tags     = var.tags
}

data "azurerm_resource_group" "existing" {
  count = var.create_resource_group ? 0 : 1
  name  = var.resource_group
}

# --- Azure Container Registry (Artifact Registry equivalent) ---
resource "azurerm_container_registry" "app" {
  name                = local.acr_name
  resource_group_name = local.rg_name
  location            = local.rg_location
  sku                 = var.acr_sku
  admin_enabled       = false # pulls use the managed identity below, not an admin user
  tags                = var.tags
}

# --- Runtime identity (least privilege: pull images + read secrets, nothing else) ---
resource "azurerm_user_assigned_identity" "app" {
  name                = "${var.service_name}-id"
  resource_group_name = local.rg_name
  location            = local.rg_location
  tags                = var.tags
}

resource "azurerm_role_assignment" "acr_pull" {
  scope                = azurerm_container_registry.app.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}

resource "azurerm_role_assignment" "kv_secrets_user" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}

# Terraform itself writes the three secrets, and the vault uses RBAC (not access policies), so the
# principal running `apply` needs write access. Role assignments are eventually consistent — if the
# first apply fails with a 403 on the secrets, re-run it (see README).
resource "azurerm_role_assignment" "deployer_kv_secrets_officer" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# --- Azure Database for PostgreSQL, Flexible Server (Cloud SQL equivalent) ---
resource "azurerm_postgresql_flexible_server" "pg" {
  name                          = "${var.service_name}-pg-${local.suffix}"
  resource_group_name           = local.rg_name
  location                      = local.rg_location
  version                       = var.db_version
  administrator_login           = var.db_user
  administrator_password        = var.db_password
  sku_name                      = var.db_sku_name
  storage_mb                    = var.db_storage_mb
  backup_retention_days         = var.db_backup_retention_days
  zone                          = var.db_zone
  auto_grow_enabled             = true
  public_network_access_enabled = true # sandbox posture; prod = private endpoint / VNet (§10)
  tags                          = var.tags

  lifecycle {
    # Azure may relocate the server's zone on maintenance; don't fight it on every plan.
    ignore_changes = [zone]
  }
}

resource "azurerm_postgresql_flexible_server_database" "db" {
  name      = var.db_name
  server_id = azurerm_postgresql_flexible_server.pg.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# The app reaches Postgres via the "allow Azure services" rule (the 0.0.0.0/0.0.0.0 sentinel —
# Azure-internal traffic only, not the internet). App Service *does* publish its outbound IPs
# (see the `app_outbound_ips` output), unlike Container Apps, so this could be tightened to those
# CIDRs — but they change whenever the plan is scaled up/down or the app is moved, which would
# silently break the DB connection. Prod answer is VNet integration + a private endpoint (§10).
resource "azurerm_postgresql_flexible_server_firewall_rule" "azure_services" {
  name             = "allow-azure-services"
  server_id        = azurerm_postgresql_flexible_server.pg.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "admin" {
  for_each         = { for r in var.db_allowed_ip_ranges : r.name => r }
  name             = each.value.name
  server_id        = azurerm_postgresql_flexible_server.pg.id
  start_ip_address = each.value.start_ip_address
  end_ip_address   = each.value.end_ip_address
}

# --- Key Vault (Secret Manager equivalent) ---
resource "azurerm_key_vault" "kv" {
  name                       = local.kv_name
  resource_group_name        = local.rg_name
  location                   = local.rg_location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = false # temporary home (§9.3) — keep teardown clean
  soft_delete_retention_days = 7
  tags                       = var.tags
}

resource "azurerm_key_vault_secret" "app_db_url" {
  name         = "app-db-url"
  value        = local.app_db_url
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [azurerm_role_assignment.deployer_kv_secrets_officer]
}

resource "azurerm_key_vault_secret" "jira_api_token" {
  name         = "jira-api-token"
  value        = var.jira_api_token
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [azurerm_role_assignment.deployer_kv_secrets_officer]
}

# The BigQuery read-only SA key (§3.3). The whole reason this module needs a vault-held credential
# where the GCP module needed none. NOTE: this resolves into an *app setting* on App Service rather
# than a mounted Container Apps secret. It's ~2.3 KB of JSON, well inside the app-setting limit, and
# Linux App Service passes multi-line values through to the container env intact — but §11.3's
# "BigQuery read works using only the Key-Vault key" check is the one that proves it end to end.
resource "azurerm_key_vault_secret" "bq_service_account_json" {
  name         = "bq-service-account-json"
  value        = var.google_service_account_json
  key_vault_id = azurerm_key_vault.kv.id
  content_type = "application/json"
  depends_on   = [azurerm_role_assignment.deployer_kv_secrets_officer]
}

# --- Log Analytics ---
# Container Apps *required* a workspace (it was the environment's log sink). App Service doesn't, but
# without one the only logs are the short-lived filesystem stream — so keep it and wire a diagnostic
# setting, which is what makes container stdout queryable after the fact.
resource "azurerm_log_analytics_workspace" "law" {
  name                = "${var.service_name}-logs"
  resource_group_name = local.rg_name
  location            = local.rg_location
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  tags                = var.tags
}

# --- App Service plan (Cloud Run / Container Apps Environment equivalent) ---
resource "azurerm_service_plan" "app" {
  name                = "${var.service_name}-plan"
  resource_group_name = local.rg_name
  location            = local.rg_location
  os_type             = "Linux" # required for Web App for Containers
  sku_name            = var.app_service_sku
  worker_count        = var.app_service_worker_count
  tags                = var.tags
}

# --- App Service (Linux, Web App for Containers) ---
resource "azurerm_linux_web_app" "app" {
  name                = local.web_app_name
  resource_group_name = local.rg_name
  location            = azurerm_service_plan.app.location # must match the plan's region
  service_plan_id     = azurerm_service_plan.app.id
  https_only          = true
  tags                = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  # Without this, App Service resolves @Microsoft.KeyVault(...) references with the *system*-assigned
  # identity (which doesn't exist here) and every secret app setting silently fails to resolve.
  key_vault_reference_identity_id = azurerm_user_assigned_identity.app.id

  site_config {
    # The plan is always allocated, so keep the app resident: no cold start, and the daily run isn't
    # racing an unload. (Not available on Free/Shared SKUs — see the validation on var.app_service_sku.)
    always_on           = var.always_on
    ftps_state          = "Disabled"
    minimum_tls_version = "1.2"
    http2_enabled       = true

    # Dependency-free 200 from wonder/api/routes.py:125 — deliberately not /api/runinfo, which hits
    # the DB and would fail the app out of rotation on a Postgres blip.
    health_check_path                 = "/api/health"
    health_check_eviction_time_in_min = 10

    # ACR pull via the user-assigned identity (the AcrPull assignment above). No admin user, no
    # registry password in state.
    container_registry_use_managed_identity       = true
    container_registry_managed_identity_client_id = azurerm_user_assigned_identity.app.client_id

    application_stack {
      docker_image_name   = local.image_repo_tag
      docker_registry_url = "https://${local.image_registry}"
    }

    # Container Apps put the allowlist on `ingress`; App Service puts it on site_config and needs an
    # explicit default action. "Deny" + an empty list would lock everyone out, so only flip the
    # default when there is actually something in the allowlist (the `check` block below warns).
    ip_restriction_default_action = (!var.allow_unauthenticated && length(var.ingress_allowed_ip_ranges) > 0) ? "Deny" : "Allow"

    dynamic "ip_restriction" {
      for_each = var.allow_unauthenticated ? [] : var.ingress_allowed_ip_ranges
      content {
        name       = ip_restriction.value.name
        ip_address = ip_restriction.value.ip_address_range
        action     = "Allow"
        priority   = 100 + index(var.ingress_allowed_ip_ranges, ip_restriction.value)
      }
    }

    # The SCM/Kudu endpoint (deployments, log stream, SSH) follows the same allowlist.
    scm_use_main_ip_restriction = !var.allow_unauthenticated && length(var.ingress_allowed_ip_ranges) > 0
  }

  app_settings = merge(
    {
      # Container Apps took `ingress.target_port`; App Service probes port 80 unless told otherwise.
      # It also injects $PORT into the container, which the Dockerfile's CMD already honours.
      WEBSITES_PORT = "8000"

      # --- Plain config (mirrors the GCP module's container env block) ---
      DATA_SOURCE            = "bigquery"
      TICKET_SINK            = "jira"
      GCP_PROJECT            = var.bq_project
      BQ_DATASET             = var.bq_dataset
      BQ_LEDGER_TABLE        = var.bq_ledger_table
      BQ_PO_TABLE            = var.bq_po_table
      BQ_CATALOG_DATASET     = var.bq_catalog_dataset
      BQ_PRODUCTS_TABLE      = var.bq_products_table
      ERP_PROJECT            = var.erp_bq_project
      ERP_DATASET            = var.erp_bq_dataset
      JIRA_BASE_URL          = var.jira_base_url
      JIRA_EMAIL             = var.jira_email
      JIRA_PROJECT_KEY       = var.jira_project_key
      JIRA_ISSUE_TYPE        = var.jira_issue_type
      JIRA_DONE_TRANSITION   = var.jira_done_transition
      JIRA_FINGERPRINT_FIELD = var.jira_fingerprint_field

      # The daily run is driven externally (§7). Keep the in-app APScheduler off so the run isn't
      # double-triggered. (On Container Apps it also couldn't fire reliably while scaling to zero;
      # with always_on it *would* work here, but one trigger owner is still the right design.)
      SCHEDULER_ENABLED = "false"
    },
    # --- Secrets, as Key Vault references resolved by the user-assigned identity ---
    local.kv_refs,
  )

  # Surfaces container stdout in `az webapp log tail` / the portal log stream. The diagnostic
  # setting below is what retains it for querying.
  logs {
    application_logs {
      file_system_level = "Information"
    }
    http_logs {
      file_system {
        retention_in_days = 7
        retention_in_mb   = 35
      }
    }
  }

  depends_on = [
    azurerm_role_assignment.acr_pull,
    azurerm_role_assignment.kv_secrets_user,
    azurerm_postgresql_flexible_server_database.db,
    azurerm_postgresql_flexible_server_firewall_rule.azure_services,
  ]
}

resource "azurerm_monitor_diagnostic_setting" "app" {
  name                       = "${var.service_name}-diag"
  target_resource_id         = azurerm_linux_web_app.app.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id

  # Container stdout/stderr (the app's own logging), the HTTP access log, and the platform log that
  # records image pulls and container start failures — the three you need to debug a bad deploy.
  enabled_log {
    category = "AppServiceConsoleLogs"
  }
  enabled_log {
    category = "AppServiceHTTPLogs"
  }
  enabled_log {
    category = "AppServicePlatformLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

# `allow_unauthenticated = false` on its own does NOT protect the console — it only narrows ingress
# to var.ingress_allowed_ip_ranges. With an empty list the app stays reachable by anyone, which is
# almost certainly not what was intended. Warn rather than fail: the legitimate false-with-empty-list
# case is "Entra ID Easy Auth is configured" (§6), which this module can't detect.
check "ingress_is_actually_restricted" {
  assert {
    condition     = var.allow_unauthenticated || length(var.ingress_allowed_ip_ranges) > 0
    error_message = "allow_unauthenticated=false but ingress_allowed_ip_ranges is empty: ingress is still open to the internet. Add the client's CIDRs, or configure Entra ID Easy Auth on the App Service (GO-LIVE-AZURE.md §6 — now a first-class App Service feature, azurerm_linux_web_app_auth_settings_v2)."
  }
}
