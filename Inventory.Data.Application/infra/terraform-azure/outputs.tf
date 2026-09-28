output "app_url" {
  description = "Public HTTPS URL of the console (App Service default hostname)."
  value       = local.app_url
}

output "app_service_name" {
  description = "App Service (web app) name — for `az webapp log tail`, restarts, and `az webapp config container set`."
  value       = azurerm_linux_web_app.app.name
}

output "app_service_plan" {
  description = "App Service plan hosting the console, and its SKU."
  value = {
    name         = azurerm_service_plan.app.name
    sku          = azurerm_service_plan.app.sku_name
    worker_count = azurerm_service_plan.app.worker_count
  }
}

output "acr_login_server" {
  description = "Registry to push the app image to (`az acr login --name <acr_name>`)."
  value       = azurerm_container_registry.app.login_server
}

output "acr_name" {
  description = "Azure Container Registry name (used by `az acr login`)."
  value       = azurerm_container_registry.app.name
}

output "image_repository" {
  description = "Full image path to build/push, minus the tag."
  value       = "${azurerm_container_registry.app.login_server}/${var.service_name}/app"
}

output "postgres_fqdn" {
  description = "PostgreSQL Flexible Server hostname (for one-off psql/alembic access; add your IP to db_allowed_ip_ranges first)."
  value       = azurerm_postgresql_flexible_server.pg.fqdn
}

output "app_outbound_ips" {
  description = "The App Service's outbound IPs. Reaching Postgres does not need these (the allow-azure-services rule covers it), but they're what you'd allowlist on any client-side firewall — e.g. if Jira is IP-restricted. They change when the plan is scaled or the app is moved, so don't hard-depend on them."
  value       = azurerm_linux_web_app.app.outbound_ip_address_list
}

output "key_vault_name" {
  description = "Key Vault holding app-db-url, jira-api-token and bq-service-account-json."
  value       = azurerm_key_vault.kv.name
}

output "runtime_identity" {
  description = "User-assigned managed identity used by the App Service (ACR pull + Key Vault reference resolution) and the Function App."
  value = {
    name         = azurerm_user_assigned_identity.app.name
    client_id    = azurerm_user_assigned_identity.app.client_id
    principal_id = azurerm_user_assigned_identity.app.principal_id
  }
}

output "log_analytics_workspace" {
  description = "Workspace the App Service diagnostic setting writes to (container stdout, HTTP access log, platform log)."
  value       = azurerm_log_analytics_workspace.law.name
}

output "daily_run_trigger" {
  description = "Which nightly trigger was provisioned, and its resource name."
  value = {
    kind = var.daily_run_trigger
    name = local.use_functions ? azurerm_linux_function_app.daily_run[0].name : (local.use_logicapp ? azurerm_logic_app_workflow.daily_run[0].name : "none")
    # Functions: the schedule is an NCRONTAB app setting. Logic App: hour/minute on the trigger.
    schedule  = local.ncrontab
    time_zone = local.use_logicapp ? var.scheduler_time_zone_windows : var.scheduler_time_zone
    target    = local.run_uri
  }
}

output "function_app_name" {
  description = "Function App to publish ./functions/daily_run into (null unless daily_run_trigger=\"functions\")."
  value       = local.use_functions ? azurerm_linux_function_app.daily_run[0].name : null
}
