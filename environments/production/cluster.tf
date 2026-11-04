module "ecs_cluster" {
  source = "../../modules/ecs-cluster"

  name                  = local.name
  vpc_id                = module.network.vpc_id
  subnet_ids            = module.network.public_subnet_ids
  alb_security_group_id = aws_security_group.alb.id
  instance_type         = var.ecs_instance_type
  min_size              = var.ecs_min_instances
  max_size              = var.ecs_max_instances
  # small internal apps (other Terraform roots) run on Fargate, not on these hosts
  enable_fargate = true
  tags           = local.tags
}

# --- images --------------------------------------------------------------------------

# One image per app (docker/postiz-app.Dockerfile), pushed as <app>-<git sha>
# (immutable). The deploy workflow moves <app>-production, migrate (the db push
# task's image) and migrate-production. "production" is the all-in-one image from
# before the split, kept for rollbacks.
resource "aws_ecr_repository" "app" {
  name                 = local.app_repository
  image_tag_mutability = "IMMUTABLE_WITH_EXCLUSION"

  # the release tags the deploy workflow moves: production (the all-in-one image
  # from before the per-app split), <app>-production, and migrate-production (the
  # schema the database has)
  image_tag_mutability_exclusion_filter {
    filter      = "*production"
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

# A service is only pointed at a release tag that exists (the first time, a
# build_only run of deploy-postiz builds them): a missing tag fails the plan here
# rather than leaving the service unable to pull its image. Read by name, not
# through the repository resource, so the check always runs at plan time. Skipped
# while the apps are off, so a new environment can be created before any image.
data "aws_ecr_image" "app" {
  for_each        = var.apps_enabled ? toset(local.apps) : toset([])
  repository_name = local.app_repository
  image_tag       = "${each.key}-${var.app_image_tag}"
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
    # An image kept by a higher-priority rule is never expired by a later one, so
    # rules 1 and 2 protect the images the services and the db push task run, however
    # old: with one image per app, an app that rarely changes would otherwise fall
    # out of "the last N" while frontend releases pile up.
    rules = [
      {
        rulePriority = 1
        description  = "Keep every image a release tag points at"
        selection    = { tagStatus = "tagged", tagPatternList = ["*production"], countType = "imageCountMoreThan", countNumber = 100 }
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
        description  = "Keep the last 80 builds for rollbacks"
        selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 80 }
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
