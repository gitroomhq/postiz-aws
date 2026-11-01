locals {
  name          = "${var.project}-${var.environment}"
  secret_prefix = "${var.project}/${var.environment}"

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Repository  = var.github_repository
  }

  internal_domain        = "postiz.internal"
  temporal_frontend_host = "temporal-frontend.${local.internal_domain}"
  elasticsearch_host     = "elasticsearch.${local.internal_domain}"
  temporal_address       = "${local.temporal_frontend_host}:7233"

  # one slim image per app (docker/postiz-app.Dockerfile), each with its own release
  # tag: frontend-production, backend-production, orchestrator-production. Read
  # through data.aws_ecr_image.app, so a missing tag fails the plan (cluster.tf).
  app_repository = "postiz-app"
  apps           = ["frontend", "backend", "orchestrator"]
  app_images = {
    for app in local.apps :
    app => "${aws_ecr_repository.app.repository_url}:${try(data.aws_ecr_image.app[app].image_tag, "${app}-${var.app_image_tag}")}"
  }
  migrate_image = "${aws_ecr_repository.app.repository_url}:migrate"
  ops_image     = "${aws_ecr_repository.ops.repository_url}:latest"

  # Env var names per service, copied from Railway (scripts/railway-env-to-secrets.py
  # regenerates it). Every name becomes an ECS secret read from the service's
  # Secrets Manager JSON, so adding a variable = put the value + add the name here.
  app_env_keys = jsondecode(file("${path.module}/app-env-keys.json"))

  app_secrets = {
    for svc, keys in local.app_env_keys :
    svc => { for k in keys : k => "${aws_secretsmanager_secret.app[svc].arn}:${k}::" }
  }

  redis_url_secret = {
    REDIS_URL = "${aws_secretsmanager_secret.redis.arn}:url::"
  }
}
