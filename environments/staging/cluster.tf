# Fargate only: no hosts to patch or pay for while idle.
resource "aws_ecs_cluster" "main" {
  name = local.name

  # Container Insights bills per metric; staging gets by with the service metrics
  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = var.fargate_spot ? "FARGATE_SPOT" : "FARGATE"
    weight            = 1
  }
}

# --- images --------------------------------------------------------------------------
# One image per app (docker/postiz-app.Dockerfile, the same as production's),
# pushed as <app>-<git sha>. deploy-staging.yml moves <app>-staging, migrate and
# migrate-staging. postiz-ops is the toolbox the db init task runs.

resource "aws_ecr_repository" "app" {
  name                 = local.app_repository
  image_tag_mutability = "IMMUTABLE_WITH_EXCLUSION"

  image_tag_mutability_exclusion_filter {
    filter      = "*staging"
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

# A service is only pointed at a release tag that exists: a missing tag fails the
# plan here. Skipped while the apps are off, so the environment can be created
# before any image.
data "aws_ecr_image" "app" {
  for_each        = var.apps_enabled ? toset(local.apps) : toset([])
  repository_name = local.app_repository
  image_tag       = "${each.key}-${var.app_image_tag}"
}

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
        description  = "Keep every image a release tag points at"
        selection    = { tagStatus = "tagged", tagPatternList = ["*staging"], countType = "imageCountMoreThan", countNumber = 100 }
        action       = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the image the db push task runs"
        selection    = { tagStatus = "tagged", tagPatternList = ["migrate"], countType = "imageCountMoreThan", countNumber = 100 }
        action       = { type = "expire" }
      },
      {
        rulePriority = 3
        description  = "Drop untagged layers after a week"
        selection    = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 7 }
        action       = { type = "expire" }
      },
      {
        rulePriority = 4
        description  = "Keep the last 30 builds"
        selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 30 }
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
      description  = "Keep the last 3 toolbox images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 3 }
      action       = { type = "expire" }
    }]
  })
}

# --- task execution role -------------------------------------------------------------
# Used by ECS (not the app) to pull images, write logs and resolve the secrets in
# the task definitions.

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
