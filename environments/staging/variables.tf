variable "aws_account_id" {
  description = "The staging account, the only one this stack may touch (TF_VAR_aws_account_id)."
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
  default = "staging"
}

variable "github_repository" {
  description = "owner/name of this repository (tags only)."
  type        = string
}

variable "github_oidc_subject" {
  description = "Start of the sub claim in this repository's GitHub OIDC tokens, as in bootstrap/staging."
  type        = string
  default     = "repo:gitroomhq@128401275/postiz-aws@1436140501"
}

variable "deploy_github_environment" {
  description = "GitHub environment whose jobs may assume the deploy role (deploy-staging.yml). Limit it to main in the repository settings."
  type        = string
  default     = "staging"
}

variable "vpc_cidr" {
  type = string
}

variable "apps_enabled" {
  description = "false: every service at 0 tasks and no image check, so the environment can be created before the first build."
  type        = bool
  default     = false
}

# --- names ----------------------------------------------------------------------------

variable "cloudflare_zone_name" {
  type = string
}

variable "api_domain" {
  type = string
}

variable "mcp_domain" {
  description = "Served by the backend (staging runs no separate mcp service)."
  type        = string
}

variable "frontend_domain" {
  type = string
}

# --- who gets in ------------------------------------------------------------------------

variable "client_ca_file" {
  description = "The certificate authority whose client certificates the load balancer accepts, relative to this directory. scripts/staging-certs.py init writes it."
  type        = string
  default     = "client-ca.pem"
}

variable "client_certificates_required" {
  description = <<-EOT
    true: port 443 is open to everyone, and the load balancer ends every
    connection that does not present a client certificate of client_ca_file.
    false: no certificate is asked for, and port 443 only accepts
    open_to_cidrs (a pentest whose tools cannot present a certificate).
  EOT
  type        = bool
  default     = true
}

variable "open_to_cidrs" {
  description = "Without client certificates, the only addresses port 443 accepts: IPv4 ranges of /16 or narrower."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.open_to_cidrs : can(cidrhost(c, 0)) && can(regex("^[0-9.]+/[0-9]+$", c)) && tonumber(split("/", c)[1]) >= 16])
    error_message = "open_to_cidrs must name addresses (IPv4, /16 or narrower): anything wider would put staging on the internet without a certificate check."
  }
}

variable "stripe_webhook_ips" {
  description = "Where Stripe sends webhooks from (https://stripe.com/files/ips/ips_webhooks.json, read 2026-11-25). Only they reach port 8443, and only POST /stripe."
  type        = list(string)
  default = [
    "3.18.12.63", "3.69.109.8", "3.120.168.93", "3.130.192.231", "13.235.14.237",
    "13.235.122.149", "18.211.135.69", "35.154.171.200", "35.157.207.129", "52.15.183.38",
    "54.88.130.119", "54.88.130.237", "54.187.174.169", "54.187.205.235", "54.187.216.72",
  ]
}

# --- sizes ------------------------------------------------------------------------------

variable "fargate_spot" {
  description = "Run the services on Fargate Spot (about 70% cheaper; a task can be stopped with two minutes' notice and comes back by itself). One-off tasks always run on regular Fargate."
  type        = bool
  default     = true
}

variable "app_image_tag" {
  description = "Release tag suffix the services run: <app>-staging, moved by deploy-staging.yml."
  type        = string
  default     = "staging"
}

variable "postgres_engine_version" {
  type = string
}

variable "db_instance_class" {
  type = string
}

variable "db_allocated_storage" {
  type    = number
  default = 20
}

variable "redis_node_type" {
  type = string
}

variable "redis_engine_version" {
  type = string
}

variable "temporal_image" {
  description = "temporalio/auto-setup pinned by digest, production's build."
  type        = string
}

variable "temporal_ui_image" {
  type = string
}

variable "temporal_num_history_shards" {
  description = "Fixed for the life of the Temporal cluster."
  type        = number
  default     = 4
}

variable "log_retention_days" {
  type    = number
  default = 14
}

# --- email ------------------------------------------------------------------------------

variable "ses_test_recipients" {
  description = <<-EOT
    Addresses staging may email. The staging account's SES stays in the sandbox,
    where it can only send to verified addresses: each one listed here gets a
    verification email after the apply. So staging can never mail a real user.
  EOT
  type        = list(string)
  default     = []
  sensitive   = true
}

# --- alerts -----------------------------------------------------------------------------

variable "alert_emails" {
  description = "Where the security alerts, the alarms and the budget go (TF_VAR_alert_emails)."
  type        = list(string)
  default     = []
  sensitive   = true
}

variable "monthly_budget_usd" {
  description = "Budget alert: forecast above it, or 80% of it spent."
  type        = number
  default     = 150
}

variable "cost_anomaly_threshold_usd" {
  description = "Cost anomaly alert, per AWS service, in dollars of unexpected spend."
  type        = number
  default     = 25
}

variable "guardduty_runtime_monitoring" {
  description = "GuardDuty's agent as a sidecar in every Fargate task (reverse shells, crypto miners, odd processes). Takes up to 128 MiB of each task's memory."
  type        = bool
  default     = true
}

variable "expected_change_role_names" {
  description = "Roles whose changes do not alert (audit-trail.tf): the GitHub terraform apply role of bootstrap/staging, which only runs on main."
  type        = list(string)
  default     = ["postiz-staging-github-terraform-apply"]
}

variable "quiet_session_documents" {
  description = "Session Manager documents whose sessions do not alert as a shell: the port forward to the Temporal UI (scripts/staging-temporal-ui.sh)."
  type        = list(string)
  default     = ["AWS-StartPortForwardingSession"]
}

# --- rotations: bump to replace the value in the same apply ------------------------------

variable "main_db_password_version" {
  type    = number
  default = 1
}

variable "app_db_password_version" {
  description = "The api and worker roles' passwords (databases.tf). After bumping: apply, deploy with init_database, then roll the services."
  type        = number
  default     = 1
}

variable "temporal_db_password_version" {
  type    = number
  default = 1
}

variable "redis_auth_token_version" {
  type    = number
  default = 1
}
