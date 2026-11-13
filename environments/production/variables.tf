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
  description = "owner/name of this repository."
  type        = string
}

variable "github_oidc_subject" {
  description = <<-EOT
    Trusted by the deploy role, as in bootstrap/: start of the sub claim in this
    repository's GitHub OIDC tokens, printed by
    gh api repos/OWNER/NAME/actions/oidc/customization/sub --jq .sub_claim_prefix
    Repositories created since July 2026 carry the owner and repository ids
    (repo:owner@id/name@id), older ones repo:owner/name.
  EOT
  type        = string

  validation {
    condition     = can(regex("^repo:[^:]+$", var.github_oidc_subject))
    error_message = "Only the prefix, for example repo:owner@123/name@456 (no :ref: or :environment: part)."
  }
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

variable "ses_sending_enabled" {
  description = <<-EOT
    true sets EMAIL_PROVIDER=ses on backend, mcp, worker and worker-2, in place of
    the value in their secrets (Railway's, Resend). Turn it on only once the SES
    identity's DKIM is verified and the account has production access (ses.tf).
  EOT
  type        = bool
  default     = false
}

variable "token_encryption" {
  description = <<-EOT
    Encryption of the channel tokens in the Postiz database, on backend, mcp,
    worker and worker-2 (encryption.tf):
      off        tokens are stored plain
      read-only  the services get the key and read encrypted tokens, new
                 tokens are still stored plain
      on         new and refreshed tokens are stored encrypted
    Go off -> read-only -> on with one apply each, and run
    scripts/token-encryption-key.sh before leaving "off". Going back from "on"
    is "read-only" (encrypted tokens stay readable), never "off".
  EOT
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "read-only", "on"], var.token_encryption)
    error_message = "token_encryption must be off, read-only or on."
  }
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

variable "temporal_ui_google_client_id" {
  description = <<-EOT
    With temporal_ui_public, the load balancer sends everyone to Google's sign-in
    before the Temporal UI (its basic auth stays behind it). A Google OAuth client
    of type Web application, made in a Google Cloud project of the Workspace with
    an Internal consent screen, so only the Workspace's accounts can sign in
    (the load balancer itself never checks which account). Its redirect URI is
    https://<temporal_ui_domain>/oauth2/idpresponse.
    TF_VAR_temporal_ui_google_client_id; CI: secret TEMPORAL_UI_GOOGLE_CLIENT_ID.
    Empty: no Google sign-in, basic auth only.
  EOT
  type        = string
  default     = null
}

variable "temporal_ui_google_client_secret" {
  description = "The OAuth client's secret (TF_VAR_temporal_ui_google_client_secret; CI: secret TEMPORAL_UI_GOOGLE_CLIENT_SECRET)."
  type        = string
  default     = null
  sensitive   = true

  validation {
    condition     = try(trimspace(var.temporal_ui_google_client_id), "") == "" || try(trimspace(var.temporal_ui_google_client_secret), "") != ""
    error_message = "temporal_ui_google_client_id is set, so the Google sign-in needs its client secret too."
  }
}

variable "temporal_ui_google_domain" {
  description = "Google Workspace domain whose account Google's sign-in page offers first (the Internal consent screen is what limits sign-in to it)."
  type        = string
  default     = "postiz.com"
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
  description = "Release tag suffix: each service runs <app>-<this>, which the deploy workflow moves to each release."
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

# --- web firewall --------------------------------------------------------------------

variable "waf_enabled" {
  description = "Attach an AWS WAF web ACL to the load balancer (waf.tf). Every rule only counts until it is named in waf_blocking_rules. Billed per request, about $0.60 per million."
  type        = bool
  default     = false
}

variable "waf_blocking_rules" {
  description = <<-EOT
    Web ACL rules that block instead of count: any of ip-reputation,
    known-bad-inputs, core-rules, flood-limit, login-limit. Add one at a time,
    after reading what it counted (CloudWatch namespace AWS/WAFV2, log group
    aws-waf-logs-<name>); removing it puts the rule back to counting.
  EOT
  type        = set(string)
  default     = []

  validation {
    condition     = length(setsubtract(var.waf_blocking_rules, ["ip-reputation", "known-bad-inputs", "core-rules", "flood-limit", "login-limit"])) == 0
    error_message = "Known rules: ip-reputation, known-bad-inputs, core-rules, flood-limit, login-limit."
  }
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

variable "team_readonly_role_name" {
  description = "The team's read-only role from bootstrap/. db-readers.tf adds CloudShell inside the VPC and the database's readonly sign-in to it."
  type        = string
  default     = "postiz-team-readonly"
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
