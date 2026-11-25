# Public on purpose: everything account-specific comes from the environment
# (TF_VAR_aws_account_id, TF_VAR_alert_emails, -backend-config bucket), see
# docs/staging.md.
region            = "us-east-2"
environment       = "staging"
github_repository = "gitroomhq/postiz-aws"
# not production's 10.20.0.0/16, in case the two are ever peered or compared in logs
vpc_cidr = "10.30.0.0/16"

# On since the first images were built (docs/staging.md, step 12)
apps_enabled = true

# getpostiz.com: its own registrable domain, so staging's login cookie
# (.getpostiz.com) is never sent to production and production's never to staging
cloudflare_zone_name = "getpostiz.com"
api_domain           = "api.getpostiz.com"
mcp_domain           = "mcp.getpostiz.com"
frontend_domain      = "platform.getpostiz.com"

postgres_engine_version = "16"
db_instance_class       = "db.t4g.micro"

redis_node_type      = "cache.t4g.micro"
redis_engine_version = "8.1"

# production's builds
temporal_image    = "temporalio/auto-setup@sha256:3ee84bf3ec5494f2be6ee0c1fea3b52684e50da3ddc5f997e6fa56ad340da9a8" # 1.28.0
temporal_ui_image = "temporalio/ui@sha256:b768f87f18b59663a6749e98a2f7782c266e8e4e4749f92248e2ba41d6330d3f"         # 2.39.0

# alert_emails comes from TF_VAR_alert_emails, e.g. '["ops@example.com"]'
