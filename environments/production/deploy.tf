# Role for .github/workflows/deploy.yml and ops-image.yml: build and push the
# images, run prisma db push, roll the services.
#
# GitHub cannot assume it. Only the deploy gate can (bootstrap/deploy-gate.tf,
# applied by hand before this stack): it assumes the role for a manual run of the
# trusted commit in the "deploy" GitHub environment that was approved with a code
# from the authenticator, and passes the credentials on. The account is the
# principal and the condition names the gate's role, so the trust survives the
# gate's role being recreated.

data "aws_iam_policy_document" "deploy_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.aws_account_id}:root"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:PrincipalArn"
      values   = ["arn:aws:iam::${var.aws_account_id}:role/${var.deploy_gate_role_name}"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name               = "${local.name}-github-deploy"
  description        = "Deploys of Postiz to ${local.name}, handed out only by the deploy gate"
  assume_role_policy = data.aws_iam_policy_document.deploy_trust.json
  # the gate's sessions last an hour: a role assumed from a role cannot get more
  max_session_duration = 3600
}

locals {
  cluster_arn_prefix = "arn:aws:ecs:${var.region}:${var.aws_account_id}"
}

data "aws_iam_policy_document" "deploy" {
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "PushImages"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [aws_ecr_repository.app.arn, aws_ecr_repository.ops.arn]
  }

  # Only the Postiz services: other apps in the cluster have their own deploy roles.
  statement {
    sid       = "RollServices"
    actions   = ["ecs:UpdateService", "ecs:DescribeServices"]
    resources = [for s in sort(keys(local.postiz_services)) : "${local.cluster_arn_prefix}:service/${module.ecs_cluster.cluster_name}/${s}"]
  }

  statement {
    sid       = "RunDbPush"
    actions   = ["ecs:RunTask"]
    resources = ["${local.cluster_arn_prefix}:task-definition/${module.db_push.task_definition_family}:*"]
    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [module.ecs_cluster.cluster_arn]
    }
  }

  statement {
    sid       = "WatchTasks"
    actions   = ["ecs:DescribeTasks"]
    resources = ["${local.cluster_arn_prefix}:task/${module.ecs_cluster.cluster_name}/*"]
  }

  statement {
    sid       = "FindRunningDbPush"
    actions   = ["ecs:ListTasks"]
    resources = ["*"]
    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [module.ecs_cluster.cluster_arn]
    }
  }

  statement {
    sid       = "ReadTaskDefinitions"
    actions   = ["ecs:DescribeTaskDefinition"]
    resources = ["*"]
  }

  statement {
    sid       = "PassDbPushRoles"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.execution.arn, module.db_push.task_role_arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  statement {
    sid       = "ReadDbPushLogs"
    actions   = ["logs:GetLogEvents", "logs:FilterLogEvents"]
    resources = ["${module.db_push.log_group_arn}:*"]
  }

  # deploy-games.yml: upload postiz-games to its bucket and clear the CloudFront cache.
  statement {
    sid       = "ListGames"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.games.arn]
  }

  statement {
    sid       = "UploadGames"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.games.arn}/*"]
  }

  # the workflow finds the distribution by its domain name
  statement {
    sid       = "FindGamesDistribution"
    actions   = ["cloudfront:ListDistributions"]
    resources = ["*"]
  }

  statement {
    sid       = "RefreshGamesCache"
    actions   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"]
    resources = [aws_cloudfront_distribution.games.arn]
  }

  # The build only keeps the NEXT_PUBLIC_* keys (they end up in the browser bundle).
  statement {
    sid       = "ReadFrontendBuildValues"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.app["frontend"].arn]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "deploy"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}
