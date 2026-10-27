module "ecs_cluster" {
  source = "../../modules/ecs-cluster"

  name                  = local.name
  vpc_id                = module.network.vpc_id
  subnet_ids            = module.network.public_subnet_ids
  alb_security_group_id = aws_security_group.alb.id
  instance_type         = var.ecs_instance_type
  min_size              = var.ecs_min_instances
  max_size              = var.ecs_max_instances
  tags                  = local.tags
}

# --- images --------------------------------------------------------------------------

# One image for backend, MCP, frontend and both workers (the command differs).
# Releases are pushed as <git sha> (immutable); "migrate" and "production" are
# the two moving tags the deploy workflow updates.
resource "aws_ecr_repository" "app" {
  name                 = "postiz-app"
  image_tag_mutability = "IMMUTABLE_WITH_EXCLUSION"

  image_tag_mutability_exclusion_filter {
    filter      = "production"
    filter_type = "WILDCARD"
  }

  image_tag_mutability_exclusion_filter {
    filter      = "migrate"
    filter_type = "WILDCARD"
  }

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

# Migration toolbox: PostgreSQL 16 client tools + python + scripts/.
resource "aws_ecr_repository" "ops" {
  name                 = "postiz-ops"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Drop untagged layers after a week"
        selection    = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 7 }
        action       = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the last 40 releases for rollbacks"
        selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 40 }
        action       = { type = "expire" }
      },
    ]
  })
}

resource "aws_ecr_lifecycle_policy" "ops" {
  repository = aws_ecr_repository.ops.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 5 toolbox images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 5 }
      action       = { type = "expire" }
    }]
  })
}

# --- task execution role -------------------------------------------------------------
# Used by the ECS agent (not the app) to pull images, write logs and resolve
# the secrets in the task definitions.

data "aws_iam_policy_document" "execution_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.aws_account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:ecs:${var.region}:${var.aws_account_id}:*"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${local.name}-ecs-execution"
  description        = "ECS agent for ${local.name}: image pulls, logs, secrets"
  assume_role_policy = data.aws_iam_policy_document.execution_trust.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "execution_secrets" {
  statement {
    sid       = "ReadPostizSecrets"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:aws:secretsmanager:${var.region}:${var.aws_account_id}:secret:${local.secret_prefix}/*"]
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  name   = "read-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets.json
}
