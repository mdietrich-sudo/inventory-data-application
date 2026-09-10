# --- Azure targeting ---
variable "subscription_id" {
  description = "Azure subscription to deploy into (Pavel's team's subscription per GO-LIVE-AZURE.md §0). Possibly a TEMPORARY home — see var.tags."
  type        = string
}

variable "resource_group" {
  description = "Resource group name. Created when create_resource_group=true, otherwise it must already exist and is looked up."
  type        = string
  default     = "wonder-dq"
}

variable "create_resource_group" {
  description = "Create the resource group (true) or reuse the client's existing one (false). See GO-LIVE-AZURE.md §8.1."
  type        = bool
  default     = true
}

variable "location" {
  description = "Azure region for every resource. Match the region the client's other apps use (GO-LIVE-AZURE.md §0)."
  type        = string
  default     = "eastus"
}

variable "service_name" {
  description = "Base name for the Container App and related resources."
  type        = string
  default     = "wonder-dq"
}

variable "name_suffix" {
  description = "Suffix for globally-unique names (ACR / Key Vault / storage account). Leave null to generate a random 4-char one; pin it to keep names stable across state rebuilds."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every resource. `lifecycle` flags this as a temporary/provisional home so it's obvious what can be torn down (GO-LIVE-AZURE.md §0, §9.3)."
  type        = map(string)
  default = {
    app       = "wonder-dq"
    owner     = "wonder-inventory-dq"
    lifecycle = "temporary"
    managedBy = "terraform"
  }
}

variable "image" {
  description = "Container image to deploy (e.g. <registry>.azurecr.io/wonder-dq/app:TAG). Built from app/Dockerfile and pushed to the ACR created below — see GO-LIVE-AZURE.md §4."
  type        = string
}

variable "allow_unauthenticated" {
  description = "Expose the Container App publicly with no auth. NO SSO this launch (GO-LIVE-AZURE.md §5.3): true leaves ingress open to the internet. Set false + configure Entra ID Easy Auth (§6) at go-live; false alone only narrows ingress to var.ingress_allowed_ip_ranges, it does NOT add auth."
  type        = bool
  default     = false
}

variable "ingress_allowed_ip_ranges" {
  description = "CIDRs allowed to reach the console when allow_unauthenticated=false (the interim stand-in for SSO, GO-LIVE-AZURE.md §5.3). Ignored when allow_unauthenticated=true."
  type = list(object({
    name             = string
    ip_address_range = string
  }))
  default = []
}

# --- Azure Container Registry ---
variable "acr_sku" {
  description = "ACR SKU. Basic is fine for a single app image."
  type        = string
  default     = "Basic"
}

# --- Container Apps ---
variable "container_app_environment_id" {
  description = "Reuse an existing Container Apps Environment (the client's shared one) by resource ID. Leave null for a dedicated environment + Log Analytics workspace — the default, per GO-LIVE-AZURE.md §1.5 (easier to tear down)."
  type        = string
  default     = null
}

variable "min_replicas" {
  description = "Container App min replicas. 0 = scale to zero (cheapest; adds a cold start that also re-runs `alembic upgrade head`). Set 1 to keep the console warm."
  type        = number
  default     = 0
}

variable "max_replicas" {
  description = "Container App max replicas."
  type        = number
  default     = 2
}

variable "container_cpu" {
  description = "vCPU per replica. Must pair with container_memory per Container Apps' allowed combinations (0.5/1Gi, 1/2Gi, ...)."
  type        = number
  default     = 0.5
}

variable "container_memory" {
  description = "Memory per replica (see container_cpu)."
  type        = string
  default     = "1Gi"
}

variable "log_retention_days" {
  description = "Log Analytics retention (only used when this module creates the workspace)."
  type        = number
  default     = 30
}

# --- Azure Database for PostgreSQL, Flexible Server ---
variable "db_sku_name" {
  description = "Flexible Server SKU. B_Standard_B1ms is sandbox-shaped; bump (+ zone-redundant HA) for prod — GO-LIVE-AZURE.md §10."
  type        = string
  default     = "B_Standard_B1ms"
}

variable "db_storage_mb" {
  description = "Flexible Server storage in MB (32768 = 32 GiB, the minimum)."
  type        = number
  default     = 32768
}

variable "db_version" {
  description = "Postgres major version (matches the GCP module's POSTGRES_16)."
  type        = string
  default     = "16"
}

variable "db_backup_retention_days" {
  description = "Automated backup retention in days."
  type        = number
  default     = 7
}

variable "db_zone" {
  description = "Availability zone for the server. Azure rejects some zones per region/SKU; set null to let Azure pick."
  type        = string
  default     = "1"
}

variable "db_name" {
  type    = string
  default = "wonderdq"
}

variable "db_user" {
  description = "Flexible Server administrator login (the app connects as this user; Flexible Server takes a bare name, no @server suffix)."
  type        = string
  default     = "wonder"
}

variable "db_password" {
  description = "Postgres admin password. Provide via TF_VAR_db_password (env) — never commit it."
  type        = string
  sensitive   = true
}

variable "db_allowed_ip_ranges" {
  description = "Extra Postgres firewall rules, e.g. your workstation for one-off psql/alembic access. The Container App reaches the server through the built-in allow-azure-services rule, so this is only for humans."
  type = list(object({
    name             = string
    start_ip_address = string
    end_ip_address   = string
  }))
  default = []
}

# --- BigQuery (read-only source; the data does NOT move to Azure) ---
variable "bq_project" {
  description = "GCP project holding the inventory dataset (ledger + PO)."
  type        = string
  default     = "wonder-dw-prod-brd"
}

variable "erp_bq_project" {
  description = "GCP project holding the ERP standard-cost dataset (read by the COST rules)."
  type        = string
  default     = "wonder-raw-prod"
}

variable "erp_bq_dataset" {
  description = "ERP standard-cost dataset."
  type        = string
  default     = "erp_prod_batch"
}

variable "bq_dataset" {
  type    = string
  default = "inventory"
}

variable "bq_ledger_table" {
  type    = string
  default = "consolidated_inventory_ledger"
}

variable "bq_po_table" {
  type    = string
  default = "int_ledger_purchase_orders"
}

variable "bq_catalog_dataset" {
  description = "Supply-chain product/UoM catalog dataset (PO-06)."
  type        = string
  default     = "supply_chain_catalog"
}

variable "bq_products_table" {
  description = "Products table inside bq_catalog_dataset (PO-06)."
  type        = string
  default     = "wonder_products"
}

variable "google_service_account_json" {
  description = <<-EOT
    Raw JSON of the read-only BigQuery service-account key (GO-LIVE-AZURE.md §3). Azure has no GCP
    ADC, so the app reads this key instead. Stored in Key Vault and mounted into the container as
    GOOGLE_SERVICE_ACCOUNT_JSON. Provide via env, never the tfvars file:
      export TF_VAR_google_service_account_json="$(cat readonly-sa-key.json)"
    This is a long-lived credential — put rotation on the follow-up list (§10).
  EOT
  type        = string
  sensitive   = true
}

# --- Jira ---
variable "jira_base_url" {
  type = string
}

variable "jira_email" {
  type = string
}

variable "jira_project_key" {
  type    = string
  default = "WIQ"
}

variable "jira_issue_type" {
  type    = string
  default = "Task"
}

variable "jira_done_transition" {
  description = "Jira transition name used for auto-close (verify against the client's workflow — GO-LIVE-AZURE.md §8.9)."
  type        = string
  default     = "Done"
}

variable "jira_fingerprint_field" {
  description = "Optional Jira custom field (customfield_xxxxx) holding the issue fingerprint. Empty = a label is used instead."
  type        = string
  default     = ""
}

variable "jira_api_token" {
  description = "Jira API token. Provide via TF_VAR_jira_api_token (env) — never commit it."
  type        = string
  sensitive   = true
}

# --- Daily validation run (-> POST /api/run) ---
variable "daily_run_trigger" {
  description = "How the nightly run is triggered (GO-LIVE-AZURE.md §7): \"functions\" = Azure Functions Timer trigger (the client's proposal; needs the one-file app in ./functions/daily_run deployed once), \"logicapp\" = Logic App Recurrence + HTTP action (zero code, fully declarative), \"none\" = provision nothing (trigger it yourself)."
  type        = string
  default     = "functions"

  validation {
    condition     = contains(["functions", "logicapp", "none"], var.daily_run_trigger)
    error_message = "daily_run_trigger must be one of: functions, logicapp, none."
  }
}

variable "scheduler_hour" {
  description = "Local hour for the daily run. 00:15 is just after the prior data day closes (matches the GCP module)."
  type        = number
  default     = 0
}

variable "scheduler_minute" {
  description = "Local minute for the daily run."
  type        = number
  default     = 15
}

variable "scheduler_time_zone" {
  description = "IANA time zone for the Functions timer trigger (Linux function apps use IANA names)."
  type        = string
  default     = "America/Los_Angeles"
}

variable "scheduler_time_zone_windows" {
  description = "Windows time-zone name for the Logic App Recurrence trigger (Logic Apps use Windows names, not IANA). Must denote the same zone as scheduler_time_zone."
  type        = string
  default     = "Pacific Standard Time"
}

variable "function_python_version" {
  description = "Python runtime for the Functions timer app."
  type        = string
  default     = "3.11"
}
