# Offline plan with a mocked AWS provider (archive stays real, it is local):
#   terraform -chdir=bootstrap init && terraform -chdir=bootstrap test
# Runs in memory, the stack's own state file is not read or written.

variables {
  aws_account_id = "123456789012"
  # whatever bootstrap/local.auto.tfvars says on this machine
  deploy_gate_repositories = {}
}

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_iam_role" {
    override_during = plan
    defaults        = { arn = "arn:aws:iam::123456789012:role/mock" }
  }
}

run "deploy_gate" {
  command = plan

  assert {
    condition = alltrue([
      for trust in [data.aws_iam_policy_document.apply_trust] :
      trust.statement[0].actions == toset(["sts:AssumeRole"]) && alltrue([for p in trust.statement[0].principals : p.type == "AWS"])
    ])
    error_message = "the apply role must not trust GitHub: only the gate hands it out"
  }

  assert {
    condition = toset(one([
      for c in data.aws_iam_policy_document.apply_trust.statement[0].condition : c.values if c.variable == "aws:PrincipalArn" && c.test == "ArnEquals"
    ])) == toset([aws_iam_role.deploy_gate.arn])
    error_message = "the apply role's trust must name the gate's role and nothing else"
  }

  assert {
    condition     = keys(aws_apigatewayv2_route.deploy_gate) == ["POST /credentials", "POST /open"] && alltrue([for r in aws_apigatewayv2_route.deploy_gate : r.authorization_type == "JWT"])
    error_message = "every route of the gate must sit behind the JWT authorizer"
  }

  assert {
    condition     = aws_apigatewayv2_authorizer.deploy_gate.jwt_configuration[0].issuer == "https://token.actions.githubusercontent.com" && aws_apigatewayv2_authorizer.deploy_gate.jwt_configuration[0].audience == toset(["postiz-deploy-gate"])
    error_message = "the authorizer accepts GitHub's tokens for the gate's audience only"
  }

  assert {
    condition     = keys(local.gate_repositories) == ["1436140501"] && keys(local.gate_repositories["1436140501"].targets) == ["deploy", "production"] && local.gate_repositories["1436140501"].targets.deploy.role_arn == "arn:aws:iam::123456789012:role/postiz-production-github-deploy"
    error_message = "by default the gate serves this repository only: the deploy role for the deploy environment and the apply role for production"
  }

  assert {
    condition     = local.gate_repositories["1436140501"].targets.deploy.right == "deploy" && local.gate_repositories["1436140501"].targets.production.right == "production"
    error_message = "terraform apply needs the production right, a deploy the deploy right"
  }

  assert {
    condition = toset(one([
      for st in data.aws_iam_policy_document.deploy_gate.statement : st.actions if st.sid == "GateState"
    ])) == toset(["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem"])
    error_message = "the gate reads and writes its own table and nothing more of DynamoDB"
  }

  assert {
    condition = one([
      for st in data.aws_iam_policy_document.deploy_gate.statement : st.resources if contains(st.actions, "secretsmanager:GetSecretValue")
    ]) == toset(["arn:aws:secretsmanager:us-east-2:123456789012:secret:postiz/deploy-gate/totp/*"])
    error_message = "the gate reads the authenticator secrets, one per person under its prefix, and no other secret"
  }

  assert {
    condition     = aws_lambda_function.deploy_gate.environment[0].variables.SECRET_PREFIX == "postiz/deploy-gate/totp/"
    error_message = "the function looks for the secrets where scripts/deploy-gate.sh enroll puts them"
  }
}

run "more_repositories" {
  command = plan

  variables {
    deploy_gate_repositories = {
      "5550001" = {
        name = "acme/internal"
        targets = {
          production = { role_name = "internal-apply", right = "production", approval_seconds = 7200 }
          deploy-bot = { role_name = "bot-deploy", right = "deploy" }
        }
      }
    }
  }

  assert {
    condition     = keys(local.gate_repositories) == ["1436140501", "5550001"] && local.gate_repositories["5550001"].targets["deploy-bot"] == { role_arn = "arn:aws:iam::123456789012:role/bot-deploy", right = "deploy", approval_seconds = 5400 }
    error_message = "another repository gets its own environments and roles, next to this one's"
  }

  assert {
    condition = toset(one([
      for st in data.aws_iam_policy_document.deploy_gate.statement : st.resources if st.sid == "HandOutTheGatedRoles"
    ])) == toset(["arn:aws:iam::123456789012:role/postiz-production-github-deploy", "arn:aws:iam::123456789012:role/mock", "arn:aws:iam::123456789012:role/internal-apply", "arn:aws:iam::123456789012:role/bot-deploy"])
    error_message = "the gate may assume the roles of its targets and no other"
  }
}

run "this_repository_cannot_be_redefined" {
  command = plan

  variables {
    deploy_gate_repositories = {
      "1436140501" = { name = "acme/other", targets = { deploy = { role_name = "x", right = "deploy" } } }
    }
  }

  expect_failures = [var.deploy_gate_repositories]
}
