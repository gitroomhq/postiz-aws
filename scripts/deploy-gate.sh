#!/bin/bash
# Your side of the deploy gate (bootstrap/deploy-gate.tf, README "Deploy gate"),
# run on your own machine with admin credentials for the account
# (export AWS_PROFILE=<profile>). Nothing here can be done from GitHub.
#
#   deploy-gate.sh enroll [--rotate]  create the authenticator secret, show it once
#                                     as a QR code or setup key, check a code from
#                                     your phone, then store it for the gate.
#                                     Run it in your own terminal: it prints the secret.
#   deploy-gate.sh trust [commit]     let workflow runs of this commit (default: the
#                                     head of origin/main) ask for credentials, after
#                                     showing what changed since the trusted one
#   deploy-gate.sh status             trusted commit, wrong codes, approved runs
#   deploy-gate.sh reset              unlock the gate after too many wrong codes
set -euo pipefail

TABLE=${DEPLOY_GATE_TABLE:-postiz-deploy-gate}
SECRET_ID=${DEPLOY_GATE_SECRET:-postiz/deploy-gate/totp}
export AWS_REGION=${AWS_REGION:-us-east-2} AWS_PAGER=""
ROOT=$(cd "$(dirname "$0")/.." && pwd)

fail() {
  echo "$*" >&2
  exit 1
}

item() { # key -> the item as DynamoDB JSON, empty when there is none
  aws dynamodb get-item --table-name "$TABLE" --consistent-read \
    --key "{\"id\":{\"S\":\"$1\"}}" --query Item --output json
}

trusted() {
  item config | jq -r '.trusted_sha.S // empty'
}

enrolled() {
  [ "$(aws secretsmanager describe-secret --secret-id "$SECRET_ID" \
    --query 'length(keys(VersionIdsToStages || `{}`))' --output text)" != 0 ]
}

# codes_now: the secret on stdin -> prints the codes the gate would accept now
codes_now() {
  PYTHONPATH="$ROOT/bootstrap/deploy-gate" python3 -c '
import sys, time, totp
secret = sys.stdin.read()
step = int(time.time()) // totp.PERIOD
print(" ".join(totp.code_at(secret, s) for s in range(step - 2, step + 2)))'
}

enroll() {
  if enrolled && [ "${1:-}" != --rotate ]; then
    fail "An authenticator is already enrolled. deploy-gate.sh enroll --rotate replaces it: the old entry on your phone stops working."
  fi
  [ -t 0 ] && [ -t 1 ] || fail "Run this in your own terminal: it shows the secret and asks for a code."

  local secret uri code
  secret=$(python3 -c 'import base64, secrets; print(base64.b32encode(secrets.token_bytes(20)).decode())')
  uri="otpauth://totp/Postiz:deploy-gate?secret=$secret&issuer=Postiz&algorithm=SHA1&digits=6&period=30"

  echo "Add this to Google Authenticator (or any authenticator app). It is shown once."
  echo
  if command -v qrencode > /dev/null; then
    qrencode -t ANSIUTF8 "$uri"
    echo "Or enter it by hand:"
  else
    echo "(install qrencode to get a QR code: brew install qrencode)"
    echo "In the app: + > Enter a setup key"
  fi
  echo "  account: Postiz deploy-gate"
  echo "  key:     $secret"
  echo "  type:    time based"
  echo
  read -r -p "The 6-digit code the app shows now: " code
  code=${code//[[:space:]]/}
  if ! printf %s "$secret" | codes_now | tr ' ' '\n' | grep -qx "$code"; then
    fail "That is not a code of this secret. Nothing was stored: remove the entry from the app and enroll again."
  fi

  printf %s "$secret" | aws secretsmanager put-secret-value --secret-id "$SECRET_ID" \
    --secret-string file:///dev/stdin > /dev/null
  echo "Stored. The gate accepts codes from this authenticator from now on."
  echo "Clear this terminal (the key above is the secret), and keep a second device or"
  echo "a copy of the key somewhere safe: without the authenticator, enroll --rotate is the way back."
}

trust() {
  local new old head
  git -C "$ROOT" fetch --quiet origin main
  head=$(git -C "$ROOT" rev-parse origin/main)
  new=$(git -C "$ROOT" rev-parse --verify --quiet "${1:-$head}^{commit}") || fail "no such commit: ${1:-}"
  old=$(trusted)

  if [ "$old" = "$new" ]; then
    echo "${new:0:12} is already the trusted commit."
    return
  fi
  if [ -z "$old" ]; then
    echo "No commit is trusted yet."
  elif git -C "$ROOT" cat-file -e "$old^{commit}" 2> /dev/null; then
    echo "Trusted now: ${old:0:12}. Changes up to ${new:0:12}:"
    echo
    git -C "$ROOT" --no-pager log --format='  %h %an, %ad: %s' --date=short "$old..$new"
    echo
    git -C "$ROOT" --no-pager diff --stat "$old" "$new"
    echo
    echo "Read them before you answer: git diff ${old:0:12} ${new:0:12}"
    echo "Workflows, scripts and Terraform of this commit will run with production credentials."
  else
    echo "The trusted commit ${old:0:12} is not in this clone, so there is nothing to compare with."
  fi
  if [ "$new" != "$head" ]; then
    echo "Note: ${new:0:12} is not the head of origin/main (${head:0:12}). Runs start from the head, so they will be refused."
  fi

  local answer
  read -r -p "Trust ${new:0:12}? Type yes: " answer
  [ "$answer" = yes ] || fail "Nothing changed."
  aws dynamodb put-item --table-name "$TABLE" --item "$(jq -nc --arg sha "$new" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{id: {S: "config"}, trusted_sha: {S: $sha}, trusted_at: {S: $at}}')"
  echo "Trusted: $new"
}

status() {
  local config
  config=$(item config)
  if [ "$config" = null ] || [ -z "$config" ]; then
    echo "trusted commit:  none (deploy-gate.sh trust)"
  else
    echo "trusted commit:  $(jq -r '.trusted_sha.S' <<< "$config") since $(jq -r '.trusted_at.S' <<< "$config")"
  fi
  if enrolled; then echo "authenticator:   enrolled"; else echo "authenticator:   not enrolled (deploy-gate.sh enroll)"; fi
  local failures
  failures=$(item totp | jq -r '.failures.N // "0"')
  if [ "$failures" -ge 5 ]; then
    echo "wrong codes:     $failures, the gate is LOCKED (deploy-gate.sh reset, after finding out who tried)"
  else
    echo "wrong codes:     $failures of 5 since the last right one"
  fi
  echo "approved runs:"
  aws dynamodb scan --table-name "$TABLE" --consistent-read --output json \
    --filter-expression 'begins_with(#id, :run) AND #expires > :now' \
    --expression-attribute-names '{"#id":"id","#expires":"expires"}' \
    --expression-attribute-values "{\":run\":{\"S\":\"run#\"},\":now\":{\"N\":\"$(date +%s)\"}}" \
    | jq -r '.Items | if length == 0 then "  none" else .[] |
        "  run \(.id.S | ltrimstr("run#") | sub("#"; " attempt ")), \(.environment.S), by \(.actor.S), until \(.expires.N | tonumber | strftime("%H:%M UTC"))" end'
}

reset() {
  aws dynamodb update-item --table-name "$TABLE" --key '{"id":{"S":"totp"}}' \
    --update-expression 'SET #failures = :zero' --expression-attribute-names '{"#failures":"failures"}' \
    --expression-attribute-values '{":zero":{"N":"0"}}'
  echo "Unlocked. The gate's log says who sent the wrong codes:"
  echo "  aws logs tail /aws/lambda/postiz-deploy-gate --since 1d --filter-pattern refused"
}

command -v jq > /dev/null || fail "jq is needed"
case "${1:-}" in
  enroll) enroll "${2:-}" ;;
  trust) trust "${2:-}" ;;
  status) status ;;
  reset) reset ;;
  *) fail "usage: deploy-gate.sh enroll [--rotate] | trust [commit] | status | reset" ;;
esac
