# Public on purpose: everything account-specific comes from the environment
# (TF_VAR_aws_account_id, TF_VAR_alert_emails, TF_VAR_temporal_ui_domain,
# -backend-config bucket), see README.
region              = "us-east-2"
github_repository   = "gitroomhq/postiz-aws"
github_oidc_subject = "repo:gitroomhq@128401275/postiz-aws@1436140501"
vpc_cidr            = "10.20.0.0/16"

# Cutover switches, flipped in order by docs/migration-runbook.md
apps_enabled     = false
workers_enabled  = false
maintenance_mode = false
dns_cutover      = false

cloudflare_zone_name = "postiz.com"
api_domain           = "api.postiz.com"
mcp_domain           = "mcp.postiz.com"
frontend_domain      = "platform.postiz.com"

# The Temporal UI as on Railway: basic auth on a random, unlisted hostname
# (TF_VAR_temporal_ui_domain; CI: secret TEMPORAL_UI_DOMAIN)
temporal_ui_public = true

# The load is flat. Two r8g.xlarge (4 vCPU / 32 GiB
# each) hold everything with room for one host to fail; managed scaling adds a
# third when tasks do not fit.
ecs_instance_type = "r8g.xlarge"
ecs_min_instances = 2
ecs_max_instances = 4

backend_count     = 2
backend_max_count = 4
frontend_count    = 2

# hosts both the postiz and temporal databases
postgres_engine_version = "16"
main_db_instance_class  = "db.r8g.large"
main_db_multi_az        = true

# small caches only (redis.tf); the memory alarm says when to grow
redis_node_type      = "cache.t4g.micro"
redis_engine_version = "8.1"

elasticsearch_instance_type = "r8g.medium"
elasticsearch_version       = "8.19.10"
elasticsearch_heap          = "3g"
elasticsearch_volume_size   = 50

# The exact builds Railway runs (multi-arch index digests, checked against Docker Hub)
temporal_image    = "temporalio/auto-setup@sha256:3ee84bf3ec5494f2be6ee0c1fea3b52684e50da3ddc5f997e6fa56ad340da9a8" # 1.28.0
temporal_ui_image = "temporalio/ui@sha256:b768f87f18b59663a6749e98a2f7782c266e8e4e4749f92248e2ba41d6330d3f"         # 2.39.0

# alert_emails comes from TF_VAR_alert_emails, e.g. '["ops@example.com"]'

