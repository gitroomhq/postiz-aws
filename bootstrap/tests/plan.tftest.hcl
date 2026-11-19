# Offline plan with a mocked AWS provider (archive stays real, it is local):
#   terraform -chdir=bootstrap init && terraform -chdir=bootstrap test
# Runs in memory, the stack's own state file is not read or written.

variables {
  aws_account_id = "123456789012"
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
    condition     = keys(jsondecode(aws_lambda_function.deploy_gate.environment[0].variables.TARGETS)) == ["deploy", "production"] && jsondecode(aws_lambda_function.deploy_gate.environment[0].variables.TARGETS).deploy.role_arn == "arn:aws:iam::123456789012:role/postiz-production-github-deploy"
    error_message = "the gate hands out the deploy role to the deploy environment and the apply role to production"
  }

  assert {
    condition = toset(one([
      for st in data.aws_iam_policy_document.deploy_gate.statement : st.actions if st.sid == "GateState"
    ])) == toset(["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem"])
    error_message = "the gate reads and writes its own table and nothing more of DynamoDB"
  }

  assert {
    condition = alltrue([
      for st in data.aws_iam_policy_document.deploy_gate_totp.statement :
      st.effect == "Deny" && st.actions == toset(["secretsmanager:GetSecretValue"])
    ])
    error_message = "only the gate may read the authenticator secret"
  }
}
