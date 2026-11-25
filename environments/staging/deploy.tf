# Role for .github/workflows/deploy-staging.yml: build and push the images, run
# the db init and db push tasks, roll the services.
#
# GitHub assumes it directly (OIDC, provider created by bootstrap/staging), only
# for jobs in the "staging" GitHub environment, which the repository settings
# limit to main. No code from the authenticator, unlike production: staging is
# deployed from feature branches all day, and this role reaches nothing outside
# the staging account. Anyone who can run workflows on main can deploy staging,
# and a deployed image sees staging's secrets.

data "aws_iam_policy_document" "deploy_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = ["arn:aws:iam::${var.aws_account_id}:oidc-provider/token.actions.githubusercontent.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${var.github_oidc_subject}:environment:${var.deploy_github_environment}"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = "${local.name}-github-deploy"
  description          = "Deploys of Postiz to ${local.name} from GitHub Actions (environment ${var.deploy_github_environment})"
  assume_role_policy   = data.aws_iam_policy_document.deploy_trust.json
  max_session_duration = 3600
}

locals {
  cluster_arn_prefix = "arn:aws:ecs:${var.region}:${var.aws_account_id}"
  one_off_families   = [module.db_push.task_definition_family, module.db_init.task_definition_family]
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
    sid     = "RollServices"
    actions = ["ecs:UpdateService", "ecs:DescribeServices"]
    resources = [
      for s in concat(sort(keys(local.postiz_services)), ["temporal"]) :
      "${local.cluster_arn_prefix}:service/${aws_ecs_cluster.main.name}/${s}"
    ]
  }

  statement {
    sid       = "RunOneOffTasks"
    actions   = ["ecs:RunTask"]
    resources = [for f in local.one_off_families : "${local.cluster_arn_prefix}:task-definition/${f}:*"]
    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [aws_ecs_cluster.main.arn]
    }
  }

  statement {
    sid       = "WatchTasks"
    actions   = ["ecs:DescribeTasks"]
    resources = ["${local.cluster_arn_prefix}:task/${aws_ecs_cluster.main.name}/*"]
  }

  statement {
    sid       = "FindRunningTasks"
    actions   = ["ecs:ListTasks"]
    resources = ["*"]
    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [aws_ecs_cluster.main.arn]
    }
  }

  statement {
    sid       = "ReadTaskDefinitions"
    actions   = ["ecs:DescribeTaskDefinition"]
    resources = ["*"]
  }

  statement {
    sid       = "PassOneOffRoles"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.execution.arn, module.db_push.task_role_arn, module.db_init.task_role_arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  statement {
    sid       = "ReadOneOffLogs"
    actions   = ["logs:GetLogEvents", "logs:FilterLogEvents"]
    resources = ["${module.db_push.log_group_arn}:*", "${module.db_init.log_group_arn}:*"]
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
