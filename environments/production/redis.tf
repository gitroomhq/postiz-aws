# Railway "Redis": OAuth state, API throttling, small caches.
#
# Node-based Valkey with cluster mode disabled, not ElastiCache Serverless:
# Serverless only accepts cluster-mode clients and Postiz uses a plain
# `new Redis(REDIS_URL)` ioredis client. Primary + replica in two AZs with
# automatic failover, TLS and an AUTH token.

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
  referenced_security_group_id = module.ecs_cluster.instance_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
  description                  = "Postiz backend, MCP and workers"
}

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = local.name
  description          = "Postiz cache, OAuth state and API throttling"

  engine               = "valkey"
  engine_version       = var.redis_engine_version
  parameter_group_name = "default.valkey${split(".", var.redis_engine_version)[0]}"
  node_type            = var.redis_node_type
  num_cache_clusters   = 2
  port                 = 6379

  automatic_failover_enabled = true
  multi_az_enabled           = true

  subnet_group_name  = aws_elasticache_subnet_group.redis.name
  security_group_ids = [aws_security_group.redis.id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  transit_encryption_mode    = "required"
  auth_token_wo              = ephemeral.random_password.redis.result
  auth_token_wo_version      = var.redis_auth_token_version

  snapshot_retention_limit = 3
  snapshot_window          = "06:00-07:00"
  maintenance_window       = "sun:09:00-sun:10:00"
  apply_immediately        = false
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
