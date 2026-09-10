# Wonder DQ console on Azure — Container Apps + PostgreSQL Flexible Server + Key Vault + ACR.
# Azure port of infra/terraform (GCP Cloud Run). Design + task list: docs/GO-LIVE-AZURE.md §8.
#
# What differs from the GCP module, and why:
#   * BigQuery source data does NOT move. Azure has no GCP ADC, so instead of a runtime service
#     account IAM grant, a read-only SA *key* lives in Key Vault and is mounted into the container
#     as GOOGLE_SERVICE_ACCOUNT_JSON (already supported by wonder/datasource/bigquery.py). §3.
#   * Identity is a USER-ASSIGNED managed identity, not system-assigned as §8.6 first sketched: the
#     Container App's Key Vault secret references and its ACR pull must be authorized *before* the
#     app is created, which is impossible with a system-assigned principal that only exists after
#     creation. User-assigned breaks that cycle and is the standard pattern here.

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

  rg_name     = var.create_resource_group ? azurerm_resource_group.rg[0].name : data.azurerm_resource_group.existing[0].name
  rg_location = var.create_resource_group ? azurerm_resource_group.rg[0].location : data.azurerm_resource_group.existing[0].location

  # The app reads a single APP_DB_URL. Flexible Server is a real TCP host (no unix socket like
  # Cloud SQL), and it requires TLS — hence sslmode=require.
  app_db_url = "postgresql+psycopg://${var.db_user}:${urlencode(var.db_password)}@${azurerm_postgresql_flexible_server.pg.fqdn}:5432/${var.db_name}?sslmode=require"

  # Dedicated environment unless the client's shared one is passed in (§1.5).
  create_env = var.container_app_environment_id == null
  cae_id     = local.create_env ? azurerm_container_app_environment.env[0].id : var.container_app_environment_id

  app_url = "https://${azurerm_container_app.app.ingress[0].fqdn}"
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

# Container Apps egress IPs aren't stable, so the app reaches Postgres via the "allow Azure
# services" rule (the 0.0.0.0/0.0.0.0 sentinel — Azure-internal traffic only, not the internet).
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
# where the GCP module needed none.
resource "azurerm_key_vault_secret" "bq_service_account_json" {
  name         = "bq-service-account-json"
  value        = var.google_service_account_json
  key_vault_id = azurerm_key_vault.kv.id
  content_type = "application/json"
  depends_on   = [azurerm_role_assignment.deployer_kv_secrets_officer]
}

# --- Log Analytics + Container Apps Environment (dedicated unless one is supplied) ---
resource "azurerm_log_analytics_workspace" "law" {
  count               = local.create_env ? 1 : 0
  name                = "${var.service_name}-logs"
  resource_group_name = local.rg_name
  location            = local.rg_location
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  tags                = var.tags
}

resource "azurerm_container_app_environment" "env" {
  count                      = local.create_env ? 1 : 0
  name                       = "${var.service_name}-env"
  resource_group_name        = local.rg_name
  location                   = local.rg_location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.law[0].id
  tags                       = var.tags
}

# --- Container App (Cloud Run equivalent) ---
resource "azurerm_container_app" "app" {
  name                         = var.service_name
  resource_group_name          = local.rg_name
  container_app_environment_id = local.cae_id
  revision_mode                = "Single"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  registry {
    server   = azurerm_container_registry.app.login_server
    identity = azurerm_user_assigned_identity.app.id
  }

  # Key Vault-backed secrets, resolved by the managed identity at revision start (§3.4, option 1 —
  # no app code). Versionless IDs so rotating a secret doesn't require a Terraform change.
  secret {
    name                = "app-db-url"
    key_vault_secret_id = azurerm_key_vault_secret.app_db_url.versionless_id
    identity            = azurerm_user_assigned_identity.app.id
  }

  secret {
    name                = "jira-api-token"
    key_vault_secret_id = azurerm_key_vault_secret.jira_api_token.versionless_id
    identity            = azurerm_user_assigned_identity.app.id
  }

  secret {
    name                = "bq-service-account-json"
    key_vault_secret_id = azurerm_key_vault_secret.bq_service_account_json.versionless_id
    identity            = azurerm_user_assigned_identity.app.id
  }

  ingress {
    # External either way: allow_unauthenticated=false narrows *who* can reach it (below), it does
    # not add authentication. Real auth = Entra ID Easy Auth once §6 is answered.
    external_enabled           = true
    target_port                = 8000
    transport                  = "auto"
    allow_insecure_connections = false

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }

    dynamic "ip_security_restriction" {
      for_each = var.allow_unauthenticated ? [] : var.ingress_allowed_ip_ranges
      content {
        name             = ip_security_restriction.value.name
        ip_address_range = ip_security_restriction.value.ip_address_range
        action           = "Allow"
      }
    }
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = var.max_replicas

    container {
      name   = "app"
      image  = var.image
      cpu    = var.container_cpu
      memory = var.container_memory

      # --- Plain config (mirrors the GCP module's container env block) ---
      env {
        name  = "DATA_SOURCE"
        value = "bigquery"
      }
      env {
        name  = "TICKET_SINK"
        value = "jira"
      }
      env {
        name  = "GCP_PROJECT"
        value = var.bq_project
      }
      env {
        name  = "BQ_DATASET"
        value = var.bq_dataset
      }
      env {
        name  = "BQ_LEDGER_TABLE"
        value = var.bq_ledger_table
      }
      env {
        name  = "BQ_PO_TABLE"
        value = var.bq_po_table
      }
      env {
        name  = "BQ_CATALOG_DATASET"
        value = var.bq_catalog_dataset
      }
      env {
        name  = "BQ_PRODUCTS_TABLE"
        value = var.bq_products_table
      }
      env {
        name  = "ERP_PROJECT"
        value = var.erp_bq_project
      }
      env {
        name  = "ERP_DATASET"
        value = var.erp_bq_dataset
      }
      env {
        name  = "JIRA_BASE_URL"
        value = var.jira_base_url
      }
      env {
        name  = "JIRA_EMAIL"
        value = var.jira_email
      }
      env {
        name  = "JIRA_PROJECT_KEY"
        value = var.jira_project_key
      }
      env {
        name  = "JIRA_ISSUE_TYPE"
        value = var.jira_issue_type
      }
      env {
        name  = "JIRA_DONE_TRANSITION"
        value = var.jira_done_transition
      }
      env {
        name  = "JIRA_FINGERPRINT_FIELD"
        value = var.jira_fingerprint_field
      }

      # The daily run is driven externally (§7). Keep the in-app APScheduler off so the run isn't
      # double-triggered — and it can't fire reliably anyway while replicas scale to zero.
      env {
        name  = "SCHEDULER_ENABLED"
        value = "false"
      }

      # --- Secrets ---
      env {
        name        = "APP_DB_URL"
        secret_name = "app-db-url"
      }
      env {
        name        = "JIRA_API_TOKEN"
        secret_name = "jira-api-token"
      }
      # No GCP ADC on Azure: the app builds explicit BigQuery credentials from this key (§3.5).
      env {
        name        = "GOOGLE_SERVICE_ACCOUNT_JSON"
        secret_name = "bq-service-account-json"
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

# `allow_unauthenticated = false` on its own does NOT protect the console — it only narrows ingress
# to var.ingress_allowed_ip_ranges. With an empty list the app stays reachable by anyone, which is
# almost certainly not what was intended. Warn rather than fail: the legitimate false-with-empty-list
# case is "Entra ID Easy Auth is configured" (§6), which this module can't detect.
check "ingress_is_actually_restricted" {
  assert {
    condition     = var.allow_unauthenticated || length(var.ingress_allowed_ip_ranges) > 0
    error_message = "allow_unauthenticated=false but ingress_allowed_ip_ranges is empty: ingress is still open to the internet. Add the client's CIDRs, or confirm Entra ID Easy Auth is enabled on the Container App (GO-LIVE-AZURE.md §6)."
  }
}
