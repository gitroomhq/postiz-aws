#!/bin/bash
# Your side of the deploy gate (bootstrap/deploy-gate.tf, README "Deploy gate"),
# run on your own machine with admin credentials for the account
# (export AWS_PROFILE=<profile>). Nothing here can be done from GitHub.
#
# Who may start runs. Everyone has their own authenticator, tied to their GitHub
# account: a code only opens runs its owner started.
#   deploy-gate.sh enroll <github user> [--apply] [--rotate]
#                                     give someone an authenticator: shows their
#                                     secret once as a QR code or setup key, checks
#                                     a code from their phone, then stores it for
#                                     the gate. They may deploy; with --apply also
#                                     run terraform apply. --rotate replaces the
#                                     secret of someone enrolled (new or lost phone).
#                                     Run it in your own terminal: it prints the secret.
#   deploy-gate.sh grant <github user> deploy|apply
#                                     change what someone enrolled may do
#   deploy-gate.sh revoke <github user>
#                                     take it away: from the next request on, also
#                                     for a run of theirs that is under way
#   deploy-gate.sh reset <github user>  let someone in again after too many wrong codes
#
# What may run.
#   deploy-gate.sh trust [commit]     let workflow runs of this commit (default: the
#                                     head of origin/main) ask for credentials, after
#                                     showing what changed since the trusted one
#   deploy-gate.sh status             trusted commit, who is enrolled, approved runs
set -euo pipefail

TABLE=${DEPLOY_GATE_TABLE:-postiz-deploy-gate}
SECRET_PREFIX=${DEPLOY_GATE_SECRET_PREFIX:-postiz/deploy-gate/totp/}
GATE_ROLE=${DEPLOY_GATE_ROLE:-postiz-deploy-gate}
GITHUB_API=${GITHUB_API:-https://api.github.com}
export AWS_REGION=${AWS_REGION:-us-east-2} AWS_PAGER=""
ROOT=$(cd "$(dirname "$0")/.." && pwd)

fail() {
  echo "$*" >&2
  exit 1
}

item() { # key -> the item as DynamoDB JSON, "null" when there is none
  aws dynamodb get-item --table-name "$TABLE" --consistent-read \
    --key "{\"id\":{\"S\":\"$1\"}}" --query Item --output json
}

trusted() {
  item config | jq -r '.trusted_sha.S // empty'
}

# --- people -------------------------------------------------------------------

people() { # everyone enrolled, as a JSON array of items
  aws dynamodb scan --table-name "$TABLE" --consistent-read --output json \
    --filter-expression 'begins_with(#id, :user)' \
    --expression-attribute-names '{"#id":"id"}' \
    --expression-attribute-values '{":user":{"S":"user#"}}' | jq -c .Items
}

# github_user <login>: "<numeric id> <login as GitHub spells it>". The gate knows
# people by the id: a login can be renamed, and a freed login taken by someone else.
github_user() {
  [[ $1 =~ ^[A-Za-z0-9-]+$ ]] || fail "$1 is not a GitHub user name"
  local answer
  answer=$(curl -fsS --max-time 15 -H 'Accept: application/vnd.github+json' "$GITHUB_API/users/$1") \
    || fail "GitHub knows no user $1 (or could not be reached)"
  jq -er 'select(.type == "User") | "\(.id) \(.login)"' <<< "$answer" \
    || fail "$1 is not a person's GitHub account"
}

# enrolled_user <login or id>: "<id> <login>" of someone enrolled, from the gate's
# table and not from GitHub: it has to work for an account that is gone.
enrolled_user() {
  [ -n "${1:-}" ] || fail "which GitHub user?"
  people | jq -er --arg who "$1" '
    map(select((.login.S | ascii_downcase) == ($who | ascii_downcase) or .id.S == "user#" + $who))
    | first // empty | "\(.id.S | ltrimstr("user#")) \(.login.S)"' \
    || fail "$1 has no authenticator (deploy-gate.sh status shows who has)"
}

environments() { # deploy|apply -> the GitHub environments as a DynamoDB list
  case "$1" in
    deploy) echo '{"L":[{"S":"deploy"}]}' ;;
    apply) echo '{"L":[{"S":"deploy"},{"S":"production"}]}' ;;
    *) fail "deploy or apply, not $1" ;;
  esac
}

may() { # a user item on stdin -> what they may do, in words
  jq -r '[.environments.L[]?.S] | if index("production") then "deploy and terraform apply" elif index("deploy") then "deploy" else "nothing" end'
}

# Whatever a role is allowed elsewhere, only the gate reads a secret's value: not
# the read-only roles, not the roles the gate hands out, not an admin.
only_the_gate() {
  local account
  account=$(aws sts get-caller-identity --query Account --output text)
  jq -nc --arg role "arn:aws:iam::$account:role/$GATE_ROLE" '{
    Version: "2012-10-17",
    Statement: [{
      Sid: "OnlyTheGateReadsTheValue", Effect: "Deny", Principal: "*",
      Action: "secretsmanager:GetSecretValue", Resource: "*",
      Condition: {ArnNotEquals: {"aws:PrincipalArn": $role}}
    }]
  }'
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
  local who="" level="" rotate=false arg
  for arg in "$@"; do
    case "$arg" in
      --apply) level=apply ;;
      --rotate) rotate=true ;;
      -*) fail "unknown option $arg" ;;
      *) [ -z "$who" ] || fail "one GitHub user at a time"; who=$arg ;;
    esac
  done
  [ -n "$who" ] || fail "usage: deploy-gate.sh enroll <github user> [--apply] [--rotate]"
  [ -t 0 ] && [ -t 1 ] || fail "Run this in your own terminal: it shows the secret and asks for a code."

  local found id login existing
  found=$(github_user "$who")
  id=${found%% *} login=${found#* }
  existing=$(item "user#$id")
  if [ "$existing" != null ] && [ -n "$existing" ]; then
    $rotate || fail "$login already has an authenticator and may $(may <<< "$existing").
  deploy-gate.sh enroll $login --rotate       replaces it: the old entry on their phone stops working
  deploy-gate.sh grant $login deploy|apply    changes what they may do"
    # a new phone changes nothing about what they may do, unless you say so
    [ -n "$level" ] || level=$(jq -r 'if [.environments.L[]?.S] | index("production") then "apply" else "deploy" end' <<< "$existing")
  fi
  level=${level:-deploy}

  local secret uri code
  secret=$(python3 -c 'import base64, secrets; print(base64.b32encode(secrets.token_bytes(20)).decode())')
  uri="otpauth://totp/Postiz%20deploy:$login?secret=$secret&issuer=Postiz%20deploy&algorithm=SHA1&digits=6&period=30"

  echo "The authenticator of $login (GitHub user $id), who may $(environments "$level" | jq -c '{environments: .}' | may)."
  echo "They add it to Google Authenticator (or any authenticator app). It is shown once:"
  echo "let them scan this screen, or give them the key over a channel you trust."
  echo
  if command -v qrencode > /dev/null; then
    qrencode -t ANSIUTF8 "$uri"
    echo "Or by hand:"
  else
    echo "(install qrencode to get a QR code: brew install qrencode)"
    echo "In the app: + > Enter a setup key"
  fi
  echo "  account: Postiz deploy ($login)"
  echo "  key:     $secret"
  echo "  type:    time based"
  echo
  read -r -p "The 6-digit code their app shows now: " code
  code=${code//[[:space:]]/}
  if ! printf %s "$secret" | codes_now | tr ' ' '\n' | grep -qx "$code"; then
    fail "That is not a code of this secret. Nothing was stored: remove the entry from the app and enroll again."
  fi

  # the secret first, readable only by the gate before it has a value; then the
  # item that makes them someone the gate knows
  local name="$SECRET_PREFIX$id"
  if ! aws secretsmanager describe-secret --secret-id "$name" > /dev/null 2>&1; then
    aws secretsmanager create-secret --name "$name" > /dev/null \
      --description "Deploy gate authenticator of GitHub user $login ($id). Written by scripts/deploy-gate.sh enroll, read only by the gate."
  fi
  aws secretsmanager put-resource-policy --secret-id "$name" --resource-policy "$(only_the_gate)" > /dev/null
  printf %s "$secret" | aws secretsmanager put-secret-value --secret-id "$name" \
    --secret-string file:///dev/stdin > /dev/null
  aws dynamodb put-item --table-name "$TABLE" --item "$(jq -nc --arg id "user#$id" --arg login "$login" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson environments "$(environments "$level")" \
    '{id: {S: $id}, login: {S: $login}, environments: $environments, enrolled_at: {S: $at}}')"
  echo "Stored. Runs that $login starts open with codes from this authenticator, from now on."
  echo "Clear this terminal (the key above is the secret). If the phone is lost:"
  echo "  deploy-gate.sh enroll $login --rotate"
}

grant() {
  local found id login list
  found=$(enrolled_user "${1:-}")
  id=${found%% *} login=${found#* }
  list=$(environments "${2:-}")
  aws dynamodb update-item --table-name "$TABLE" --key "{\"id\":{\"S\":\"user#$id\"}}" \
    --update-expression 'SET #environments = :list' --condition-expression 'attribute_exists(#id)' \
    --expression-attribute-names '{"#id":"id","#environments":"environments"}' \
    --expression-attribute-values "{\":list\":$list}"
  echo "$login may $(jq -c '{environments: .}' <<< "$list" | may), from the next request on."
}

revoke() {
  local found id login
  found=$(enrolled_user "${1:-}")
  id=${found%% *} login=${found#* }
  # the item first: without it the gate does not look at the secret
  aws dynamodb delete-item --table-name "$TABLE" --key "{\"id\":{\"S\":\"user#$id\"}}"
  aws secretsmanager delete-secret --secret-id "$SECRET_PREFIX$id" --force-delete-without-recovery > /dev/null
  echo "$login can no longer open the gate. A run of theirs that is under way gets no more credentials;"
  echo "the ones it already has last up to an hour."
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
  echo "who may start runs:"
  people | jq -r 'if length == 0 then "  nobody (deploy-gate.sh enroll <github user>)" else sort_by(.login.S | ascii_downcase) | .[] |
      ([.environments.L[]?.S] | if index("production") then "deploy and terraform apply" elif index("deploy") then "deploy" else "nothing" end) as $may |
      (.failures.N // "0" | tonumber) as $wrong |
      "  \(.login.S) (GitHub user \(.id.S | ltrimstr("user#"))): \($may), since \(.enrolled_at.S // "?" | .[0:10])" +
      (if $wrong >= 5 then ", LOCKED OUT after \($wrong) wrong codes (deploy-gate.sh reset \(.login.S), after finding out who tried)"
       elif $wrong > 0 then ", \($wrong) of 5 wrong codes since the last right one" else "" end) end'
  echo "approved runs:"
  aws dynamodb scan --table-name "$TABLE" --consistent-read --output json \
    --filter-expression 'begins_with(#id, :run) AND #expires > :now' \
    --expression-attribute-names '{"#id":"id","#expires":"expires"}' \
    --expression-attribute-values "{\":run\":{\"S\":\"run#\"},\":now\":{\"N\":\"$(date +%s)\"}}" \
    | jq -r '.Items | if length == 0 then "  none" else .[] |
        "  run \(.id.S | ltrimstr("run#") | sub("#"; " attempt ")), \(.environment.S), by \(.actor.S), until \(.expires.N | tonumber | strftime("%H:%M UTC"))" end'
}

reset() {
  local found id login
  found=$(enrolled_user "${1:-}")
  id=${found%% *} login=${found#* }
  aws dynamodb update-item --table-name "$TABLE" --key "{\"id\":{\"S\":\"user#$id\"}}" \
    --update-expression 'SET #failures = :zero' --condition-expression 'attribute_exists(#id)' \
    --expression-attribute-names '{"#id":"id","#failures":"failures"}' \
    --expression-attribute-values '{":zero":{"N":"0"}}'
  echo "$login can use their authenticator again. The gate's log says where the wrong codes came from:"
  echo "  aws logs tail /aws/lambda/postiz-deploy-gate --since 1d --filter-pattern refused"
  echo "If it was not them, someone has their GitHub account: deploy-gate.sh revoke $login"
}

command -v jq > /dev/null || fail "jq is needed"
case "${1:-}" in
  enroll) shift; enroll "$@" ;;
  grant) grant "${2:-}" "${3:-}" ;;
  revoke) revoke "${2:-}" ;;
  reset) reset "${2:-}" ;;
  trust) trust "${2:-}" ;;
  status) status ;;
  *) fail "usage: deploy-gate.sh enroll <github user> [--apply] [--rotate] | grant <github user> deploy|apply | revoke <github user> | reset <github user> | trust [commit] | status" ;;
esac
