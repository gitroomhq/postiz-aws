variable "aws_account_id" {
  description = "The only AWS account this stack may touch. Set TF_VAR_aws_account_id (CI: secret AWS_ACCOUNT_ID)."
  type        = string
}

variable "region" {
  type = string
}

variable "project" {
  type    = string
  default = "postiz"
}

variable "environment" {
  type    = string
  default = "production"
}

variable "github_repository" {
  description = "owner/name of this repository, trusted by the deploy role."
  type        = string
}

variable "vpc_cidr" {
  type = string
}

# --- switches -----------------------------------------------------------------------

variable "apps_enabled" {
  description = <<-EOT
    false keeps every Postiz and Temporal service at 0 tasks. It must stay false
    until the databases are restored, the Elasticsearch index is copied, the app
    secrets are filled and the first image is pushed, otherwise auto-setup and
    prisma would initialise empty databases that the restore then collides with.
  EOT
  type        = bool
  default     = false
}

variable "workers_enabled" {
  description = <<-EOT
    worker and worker-2 run only when this is also true. They are what publishes
    (every post workflow and the RUN_CRON sweep execute there), so they start at
    go-live: before that, rolling back to Railway cannot publish anything twice.
  EOT
  type        = bool
  default     = false
}

variable "maintenance_mode" {
  description = "Serve a 503 maintenance page on api, mcp and platform (X-Postiz-Bypass header still gets through). Used during the cutover."
  type        = bool
  default     = false
}

variable "dns_cutover" {
  description = "Point api, mcp and platform at AWS. Delete the old Railway records in Cloudflare first."
  type        = bool
  default     = false
}

# --- domains -------------------------------------------------------------------------

variable "cloudflare_zone_name" {
  type = string
}

variable "api_domain" {
  type = string
}

variable "mcp_domain" {
  type = string
}

variable "frontend_domain" {
  type = string
}

variable "temporal_ui_domain" {
  description = <<-EOT
    Hostname of the public Temporal UI, directly under cloudflare_zone_name.
    Keep it unlisted, like the URL Railway generates: a random name such as
    temporal-<random>.<zone>, kept out of this repository (TF_VAR_temporal_ui_domain;
    CI: secret TEMPORAL_UI_DOMAIN). The certificate covers it with a wildcard, so
    certificate transparency logs never show it either.
  EOT
  type        = string
  default     = null

  validation {
    condition     = !var.temporal_ui_public || can(regex("^[a-z0-9-]+\\.${replace(var.cloudflare_zone_name, ".", "\\.")}$", var.temporal_ui_domain))
    error_message = "With temporal_ui_public, set temporal_ui_domain (TF_VAR_temporal_ui_domain) to a name directly under cloudflare_zone_name, e.g. temporal-<random>.<zone>."
  }
}

variable "temporal_ui_public" {
  description = <<-EOT
    true serves the Temporal UI at temporal_ui_domain through the ALB, behind
    Caddy basic auth like Railway's "Temporal Basic Auth" service. false
    (default) gives it no public hostname: open it with
    scripts/temporal-ui-tunnel.sh through Session Manager.
  EOT
  type        = bool
  default     = false
}

variable "temporal_ui_allowed_cidrs" {
  description = "With temporal_ui_public, only these source CIDRs reach the UI (up to 4). Empty: anyone, basic auth only."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.temporal_ui_allowed_cidrs) <= 4
    error_message = "An ALB rule takes at most 4 source CIDRs next to its host condition."
  }
}

# --- compute -------------------------------------------------------------------------

variable "ecs_instance_type" {
  type = string
}

variable "ecs_min_instances" {
  type = number
}

variable "ecs_max_instances" {
  type = number
}

variable "app_image_tag" {
  description = "Mutable tag the deploy workflow moves to each release."
  type        = string
  default     = "production"
}

variable "backend_count" {
  type = number
}

variable "backend_max_count" {
  type = number
}

variable "frontend_count" {
  type = number
}

# --- data stores ---------------------------------------------------------------------

variable "postgres_engine_version" {
  description = "Same major as Railway (postgres-ssl:latest is PostgreSQL 16)."
  type        = string
}

variable "main_db_instance_class" {
  type = string
}

variable "main_db_multi_az" {
  type = bool
}

variable "redis_node_type" {
  type = string
}

variable "redis_engine_version" {
  type = string
}

variable "elasticsearch_instance_type" {
  type = string
}

variable "elasticsearch_version" {
  description = "Railway runs 8.19.10 (railwayapp-templates/elasticsearch commit e106ef3)."
  type        = string
}

variable "elasticsearch_heap" {
  type = string
}

variable "elasticsearch_volume_size" {
  type = number
}

# --- Temporal ------------------------------------------------------------------------

variable "temporal_image" {
  description = <<-EOT
    temporalio/auto-setup pinned by digest. The default is the exact build Railway
    runs (1.28.0, multi-arch index), so the restored history replays on the same
    server. Upgrade one minor version at a time, never during the migration.
  EOT
  type        = string
}

variable "temporal_ui_image" {
  type = string
}

variable "temporal_task_counts" {
  description = "Tasks per Temporal role once apps_enabled is true."
  type        = map(number)
  default = {
    frontend = 2
    history  = 2
    matching = 2
    worker   = 1
  }
}

variable "temporal_num_history_shards" {
  description = "Fixed for the life of the cluster. Railway never set it, so it is the default 4 (check: select count(*) from shards)."
  type        = number
  default     = 4
}

# --- operations ----------------------------------------------------------------------

variable "alert_emails" {
  description = "Alarm emails (TF_VAR_alert_emails; CI: secret ALERT_EMAILS). Sensitive, so plans and the public CI logs never show them."
  type        = list(string)
  default     = []
  sensitive   = true
}

variable "log_retention_days" {
  type    = number
  default = 30
}

# Bump to rotate a Terraform-generated password. The resource and its secret are
# rewritten together; running tasks keep the old value until they restart.
variable "main_db_password_version" {
  type    = number
  default = 1
}

variable "temporal_db_password_version" {
  type    = number
  default = 1
}

variable "redis_auth_token_version" {
  type    = number
  default = 1
}

# Elasticsearch keeps its password in its own data: after bumping this, run
# rotate-elastic-password on the host before restarting Temporal.
variable "elasticsearch_password_version" {
  type    = number
  default = 1
}
