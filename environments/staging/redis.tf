# Valkey for OAuth state, API throttling and small caches, as in production but
# one node: no replica, no failover, no snapshots. TLS and an AUTH token like
# production, since the app's client setup is part of what gets tested.

ephemeral "random_password" "redis" {
  length  = 48
  special = false
}

resource "aws_elasticache_subnet_group" "redis" {
  name       = local.name
  subnet_ids = module.network.private_subnet_ids
}

resource "aws_security_group" "redis" {
  name        = "${local.name}-redis"
  description = "Valkey for Postiz"
  vpc_id      = module.network.vpc_id
  tags        = { Name = "${local.name}-redis" }
}

resource "aws_vpc_security_group_ingress_rule" "redis_from_apps" {
  security_group_id            = aws_security_group.redis.id
  referenced_security_group_id = aws_security_group.apps.id
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
  description                  = "Postiz backend and worker"
}

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = local.name
  description          = "Postiz staging cache, OAuth state and API throttling"

  engine               = "valkey"
  engine_version       = var.redis_engine_version
  parameter_group_name = "default.valkey${split(".", var.redis_engine_version)[0]}"
  node_type            = var.redis_node_type
  num_cache_clusters   = 1
  port                 = 6379

  automatic_failover_enabled = false
  multi_az_enabled           = false

  subnet_group_name  = aws_elasticache_subnet_group.redis.name
  security_group_ids = [aws_security_group.redis.id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  transit_encryption_mode    = "required"
  auth_token_wo              = ephemeral.random_password.redis.result
  auth_token_wo_version      = var.redis_auth_token_version
  # a rotation replaces the token at once (the default, ROTATE, keeps the old one
  # working too); the services get the new REDIS_URL when they restart
  auth_token_update_strategy = "SET"

  snapshot_retention_limit = 0
  maintenance_window       = "sun:09:00-sun:10:00"
  apply_immediately        = true
}

resource "aws_secretsmanager_secret" "redis" {
  name        = "${local.secret_prefix}/managed/redis"
  description = "REDIS_URL for Postiz (rediss:// with the AUTH token), written by Terraform"
}

resource "aws_secretsmanager_secret_version" "redis" {
  secret_id = aws_secretsmanager_secret.redis.id
  secret_string_wo = jsonencode({
    url = "rediss://:${ephemeral.random_password.redis.result}@${aws_elasticache_replication_group.redis.primary_endpoint_address}:6379"
  })
  secret_string_wo_version = var.redis_auth_token_version
}
