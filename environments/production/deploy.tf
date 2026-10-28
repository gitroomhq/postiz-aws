# Role for .github/workflows/deploy.yml and ops-image.yml: build and push the
# images, run prisma db push, roll the services. Only jobs in the "deploy" GitHub
# environment can assume it: main branch only, no reviewers, so a push to the
# app deploys on its own like on Railway (terraform apply keeps "production").

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "deploy_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${var.github_oidc_subject}:environment:deploy"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = "${local.name}-github-deploy"
  description          = "GitHub Actions deploys of Postiz to ${local.name}"
  assume_role_policy   = data.aws_iam_policy_document.deploy_trust.json
  max_session_duration = 7200
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

  statement {
    sid       = "RollServices"
    actions   = ["ecs:UpdateService", "ecs:DescribeServices"]
    resources = ["${local.cluster_arn_prefix}:service/${module.ecs_cluster.cluster_name}/*"]
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
