output "app_url" {
  description = "Public HTTPS URL of the console (Container App ingress)."
  value       = local.app_url
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

output "key_vault_name" {
  description = "Key Vault holding app-db-url, jira-api-token and bq-service-account-json."
  value       = azurerm_key_vault.kv.name
}

output "runtime_identity" {
  description = "User-assigned managed identity used by the Container App (ACR pull + Key Vault read)."
  value = {
    name         = azurerm_user_assigned_identity.app.name
    client_id    = azurerm_user_assigned_identity.app.client_id
    principal_id = azurerm_user_assigned_identity.app.principal_id
  }
}

output "container_app_environment_id" {
  description = "Container Apps Environment in use (created here, or the one passed in)."
  value       = local.cae_id
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
