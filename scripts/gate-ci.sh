#!/bin/bash
# The workflows' side of the deploy gate (bootstrap/deploy-gate.tf, README "Deploy
# gate"). A job shows the gate its GitHub token, which says which repository,
# branch, commit, run and environment it is, and gets what the gate allows:
#
#   gate-ci.sh open           approve this run attempt with the code typed into the
#                             workflow's "otp" input. Once per run, first job.
#   gate-ci.sh login          credentials of the environment's role for the steps
#                             that follow (AWS_* in $GITHUB_ENV), good for an hour
#   gate-ci.sh login refresh  the same through an AWS profile that asks the gate
#                             again when they expire (terraform apply can pass an hour)
#   gate-ci.sh credentials    what that profile runs: credentials as JSON on stdout
#
# Environment: DEPLOY_GATE_URL (repository variable, output of bootstrap/), and a
# job with `permissions: id-token: write` in the "deploy" or "production"
# environment. The code is read from the event file and never from a ${{ }}
# expression, so no log shows it; it is worthless after one use anyway.
set -euo pipefail

: "${DEPLOY_GATE_URL:?set the repository variable DEPLOY_GATE_URL (terraform -chdir=bootstrap output deploy_gate_url)}"
AUDIENCE=${DEPLOY_GATE_AUDIENCE:-postiz-deploy-gate}
REGION=${AWS_REGION:-us-east-2}

fail() {
  echo "deploy gate: $*" >&2
  exit 1
}

# a new token every time: GitHub's last about five minutes
id_token() {
  if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || [ -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
    fail "no GitHub token to show: the job needs permissions: id-token: write"
  fi
  curl -fsS --retry 3 --max-time 20 -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
    "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$AUDIENCE" | jq -er .value
}

# call <route> <json body>: prints the gate's answer, fails with its message
call() {
  local token out status
  token=$(id_token) || fail "GitHub gave no token"
  out=$(mktemp)
  status=$(curl -sS --retry 3 --max-time 30 -o "$out" -w '%{http_code}' -X POST "${DEPLOY_GATE_URL%/}/$1" \
    -H "Authorization: Bearer $token" -H 'Content-Type: application/json' --data "$2") || status=000
  if [ "$status" = 200 ] && [ "$(jq -r '.ok // false' "$out" 2>/dev/null)" = true ]; then
    cat "$out"
    rm -f "$out"
    return 0
  fi
  local message
  message=$(jq -r '.message // empty' "$out" 2>/dev/null || true)
  rm -f "$out"
  case $status in
    000) fail "could not reach $DEPLOY_GATE_URL" ;;
    401) fail "the gate's address did not accept GitHub's token (${message:-no message}): check DEPLOY_GATE_URL and the audience" ;;
    *) fail "${message:-HTTP $status}" ;;
  esac
}

case "${1:-}" in
  open)
    : "${GITHUB_EVENT_PATH:?}"
    code=$(jq -r '.inputs.otp // empty' "$GITHUB_EVENT_PATH" | tr -d '[:space:]')
    [ -n "$code" ] || fail "no code: start the run with the 6 digits from the authenticator"
    echo "::add-mask::$code"
    call open "$(jq -nc --arg code "$code" '{code: $code}')" | jq -r .message
    ;;

  login)
    : "${GITHUB_ENV:?}"
    if [ "${2:-}" = refresh ]; then
      : "${RUNNER_TEMP:?}"
      self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
      mkdir -p "$RUNNER_TEMP/deploy-gate"
      printf '[profile deploy-gate]\nregion = %s\ncredential_process = "%s" credentials\n' "$REGION" "$self" \
        > "$RUNNER_TEMP/deploy-gate/config"
      # fail here, with the gate's reason, not inside the first AWS call
      call credentials '{}' > /dev/null
      {
        echo "AWS_CONFIG_FILE=$RUNNER_TEMP/deploy-gate/config"
        echo "AWS_PROFILE=deploy-gate"
        echo "AWS_REGION=$REGION"
        echo "AWS_DEFAULT_REGION=$REGION"
      } >> "$GITHUB_ENV"
      echo "credentials come from the deploy gate, renewed while this run's approval lasts"
    else
      answer=$(call credentials '{}')
      for field in AccessKeyId SecretAccessKey SessionToken; do
        value=$(jq -er ".credentials.$field" <<< "$answer") || fail "the gate's answer has no $field"
        echo "::add-mask::$value"
      done
      {
        echo "AWS_ACCESS_KEY_ID=$(jq -r .credentials.AccessKeyId <<< "$answer")"
        echo "AWS_SECRET_ACCESS_KEY=$(jq -r .credentials.SecretAccessKey <<< "$answer")"
        echo "AWS_SESSION_TOKEN=$(jq -r .credentials.SessionToken <<< "$answer")"
        echo "AWS_REGION=$REGION"
        echo "AWS_DEFAULT_REGION=$REGION"
      } >> "$GITHUB_ENV"
      echo "credentials from the deploy gate until $(jq -r .credentials.Expiration <<< "$answer")"
    fi
    ;;

  credentials)
    call credentials '{}' | jq -e '{Version: 1} + .credentials'
    ;;

  *)
    fail "usage: gate-ci.sh open | login [refresh] | credentials"
    ;;
esac
