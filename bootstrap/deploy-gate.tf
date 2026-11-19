# The deploy gate: nothing in GitHub can change production without a code from an
# authenticator app and a commit a person approved from their own machine.
#
# The two roles that change production, postiz-github-terraform-apply (main.tf)
# and the deploy role (environments/production/deploy.tf), no longer trust GitHub.
# They trust only the gate's Lambda function, which hands a workflow run one hour
# of credentials when all of this holds (deploy-gate/handler.py):
#   - the run's GitHub token says: this repository, a manual run on main, at the
#     trusted commit (scripts/deploy-gate.sh trust, run with admin credentials
#     after reading what changed), in the GitHub environment of the role
#   - or the same for another repository of the same owner that
#     var.deploy_gate_repositories names, with its own trusted commit and roles
#   - the person who started the run was given an authenticator and that
#     environment (scripts/deploy-gate.sh enroll <github user>); the gate knows
#     them by GitHub's numeric user id
#   - the run attempt was approved with a 6-digit code (workflow input "otp") of
#     that person's authenticator that was not used before; five wrong codes lock
#     that person out until scripts/deploy-gate.sh reset <github user>
#
# So a stolen GitHub account or token gets no credentials: a changed workflow is a
# new commit, which the gate refuses, and the trusted workflow does nothing
# without a code. A stolen phone opens nothing without its owner's GitHub
# account. Removing the check from a workflow removes nothing, the check is here.
#
# This stack is applied by hand and CI never applies it, so the gate is not
# something a pull request can change. The authenticator secrets, one per person,
# are written by scripts/deploy-gate.sh enroll and never by Terraform: they are in
# no state file, and only the function can read them.
#
# An HTTP API with a JWT authorizer is in front of the function: API Gateway
# verifies the GitHub token's signature, issuer, audience and dates, and the
# function decides on the claims. Any GitHub repository can get a token for this
# audience, so the claims are what counts.

locals {
  gate_name = "postiz-deploy-gate"

  # One Secrets Manager secret per person, <prefix><GitHub user id>, created by
  # scripts/deploy-gate.sh enroll with a resource policy that denies reading the
  # value to everyone but the gate: read-only roles, the roles the gate hands
  # out and admins included.
  gate_secret_prefix = "postiz/deploy-gate/totp/"

  # GitHub environment of the job -> the role its credentials are for, what the
  # person who started the run must be allowed (scripts/deploy-gate.sh enroll and
  # grant give "deploy", and "production" for terraform apply), and how long one
  # code keeps that run going. Credentials last an hour whatever this says (a
  # role assumed from a role); terraform asks again when they expire.
  gate_targets = {
    deploy = {
      role_arn         = "arn:aws:iam::${var.aws_account_id}:role/${var.deploy_role_name}"
      right            = "deploy"
      approval_seconds = 5400 # builds (up to an hour) must be done before the release job starts
    }
    production = {
      role_arn         = aws_iam_role.apply.arn
      right            = "production"
      approval_seconds = 7200
    }
  }

  # GitHub repository id -> its name and targets: this repository, and the ones
  # var.deploy_gate_repositories adds. Each has its own trusted commit.
  gate_repositories = merge(
    {
      for id, repository in var.deploy_gate_repositories : id => {
        name = repository.name
        targets = {
          for environment, target in repository.targets : environment => {
            role_arn         = "arn:aws:iam::${var.aws_account_id}:role/${target.role_name}"
            right            = target.right
            approval_seconds = target.approval_seconds
          }
        }
      }
    },
    {
      (var.github_repository_id) = {
        name    = var.github_repository
        targets = local.gate_targets
      }
    },
  )
}

# --- state: the trusted commit, used codes, approved runs ---------------------

resource "aws_dynamodb_table" "deploy_gate" {
  name                        = local.gate_name
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "id"
  deletion_protection_enabled = true

  attribute {
    name = "id"
    type = "S"
  }

  # approvals are removed a month after they end
  ttl {
    attribute_name = "ttl"
    enabled        = true
  }
}

# --- the function ---------------------------------------------------------------

data "archive_file" "deploy_gate" {
  type        = "zip"
  output_path = "${path.module}/.terraform/deploy-gate.zip"

  source {
    filename = "handler.py"
    content  = file("${path.module}/deploy-gate/handler.py")
  }
  source {
    filename = "totp.py"
    content  = file("${path.module}/deploy-gate/totp.py")
  }
}

data "aws_iam_policy_document" "deploy_gate_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "deploy_gate" {
  name               = local.gate_name
  description        = "The deploy gate's Lambda function: the only principal the terraform apply and deploy roles trust"
  assume_role_policy = data.aws_iam_policy_document.deploy_gate_trust.json
}

data "aws_iam_policy_document" "deploy_gate" {
  statement {
    sid     = "HandOutTheGatedRoles"
    actions = ["sts:AssumeRole"]
    resources = distinct(flatten([
      for repository in values(local.gate_repositories) : [for target in values(repository.targets) : target.role_arn]
    ]))
  }

  statement {
    sid       = "ReadTheAuthenticatorSecrets"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:aws:secretsmanager:${var.region}:${var.aws_account_id}:secret:${local.gate_secret_prefix}*"]
  }

  statement {
    sid       = "GateState"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem"]
    resources = [aws_dynamodb_table.deploy_gate.arn]
  }

  statement {
    sid       = "WriteLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.deploy_gate.arn}:*"]
  }
}

resource "aws_iam_role_policy" "deploy_gate" {
  name   = "deploy-gate"
  role   = aws_iam_role.deploy_gate.id
  policy = data.aws_iam_policy_document.deploy_gate.json
}

# Every decision is one JSON line: opened, credentials, refused, expired, locked,
# with the run, the commit and who started it. Never a code or a credential.
resource "aws_cloudwatch_log_group" "deploy_gate" {
  name              = "/aws/lambda/${local.gate_name}"
  retention_in_days = 400
}

resource "aws_lambda_function" "deploy_gate" {
  function_name    = local.gate_name
  description      = "Hands the terraform apply and deploy roles to approved GitHub Actions runs"
  role             = aws_iam_role.deploy_gate.arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "handler.handler"
  filename         = data.archive_file.deploy_gate.output_path
  source_code_hash = data.archive_file.deploy_gate.output_base64sha256
  timeout          = 15
  memory_size      = 256

  environment {
    variables = {
      TABLE               = aws_dynamodb_table.deploy_gate.name
      SECRET_PREFIX       = local.gate_secret_prefix
      AUDIENCE            = var.deploy_gate_audience
      REPOSITORY_OWNER_ID = var.github_repository_owner_id
      REF                 = "refs/heads/main"
      MAX_FAILURES        = "5"
      REPOSITORIES        = jsonencode(local.gate_repositories)
    }
  }

  depends_on = [aws_cloudwatch_log_group.deploy_gate, aws_iam_role_policy.deploy_gate]
}

# --- the address the workflows call ---------------------------------------------

resource "aws_apigatewayv2_api" "deploy_gate" {
  name          = local.gate_name
  description   = "The deploy gate, for GitHub Actions runs of ${var.github_repository}"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_authorizer" "deploy_gate" {
  api_id           = aws_apigatewayv2_api.deploy_gate.id
  name             = "github-actions"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    issuer   = "https://token.actions.githubusercontent.com"
    audience = [var.deploy_gate_audience]
  }
}

resource "aws_apigatewayv2_integration" "deploy_gate" {
  api_id                 = aws_apigatewayv2_api.deploy_gate.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.deploy_gate.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "deploy_gate" {
  for_each = toset(["POST /open", "POST /credentials"])

  api_id             = aws_apigatewayv2_api.deploy_gate.id
  route_key          = each.value
  target             = "integrations/${aws_apigatewayv2_integration.deploy_gate.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.deploy_gate.id
}

resource "aws_apigatewayv2_stage" "deploy_gate" {
  api_id      = aws_apigatewayv2_api.deploy_gate.id
  name        = "$default"
  auto_deploy = true

  # a deploy makes a handful of requests
  default_route_settings {
    throttling_burst_limit = 20
    throttling_rate_limit  = 5
  }
}

resource "aws_lambda_permission" "deploy_gate" {
  statement_id  = "AllowTheGateApi"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.deploy_gate.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.deploy_gate.execution_arn}/*/*"
}
