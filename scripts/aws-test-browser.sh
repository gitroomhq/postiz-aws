#!/bin/bash
# Opens a separate Chrome window (macOS) in which the frontend, API and MCP names
# lead to this AWS stack, while DNS still sends everyone else to Railway: the test
# run on empty databases (runbook A7) and checks before the cutover.
# Builds Chrome's --host-resolver-rules itself: Chrome silently drops a rule with a
# line break or a non-breaking space in it (easy to get when copying the command),
# and the window then shows the AWS frontend talking to the Railway API. A headless
# Chrome first proves the API name reaches the load balancer; only then the window opens.
# Needs Terraform initialised in environments/production and the AWS CLI logged in.
#   scripts/aws-test-browser.sh           open the test profile
#   scripts/aws-test-browser.sh --fresh   delete the test profile first (cookies, sessions)
set -euo pipefail
cd "$(dirname "$0")/.."
CHROME=${CHROME:-"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}
PROFILE=${PROFILE_DIR:-"$HOME/.postiz-aws-test"}
ENV_DIR=environments/production

var() { sed -n "s/^$1 *= *\"\(.*\)\"/\1/p" "$ENV_DIR/terraform.tfvars"; }
frontend=$(var frontend_domain)
api=$(var api_domain)
mcp=$(var mcp_domain)
cf=$(terraform -chdir="$ENV_DIR" output -raw cloudfront_domain)
alb=$(terraform -chdir="$ENV_DIR" output -raw alb_dns_name)
rules="MAP $frontend $cf, MAP $api $alb, MAP $mcp $alb"

# a running instance keeps the flags it started with
if pgrep -f -- "--user-data-dir=$PROFILE" > /dev/null; then
  echo "The test window is still open: quit it (Cmd+Q in that window), then run this again" >&2
  exit 1
fi
if [ "${1:-}" = --fresh ]; then rm -rf "$PROFILE"; fi

check=$(mktemp -d)
trap 'rm -rf "$check"' EXIT
"$CHROME" --headless=new --disable-gpu --user-data-dir="$check/profile" --log-net-log="$check/netlog.json" \
  --host-resolver-rules="$rules" --dump-dom "https://$api/" > /dev/null 2>&1 || true
hit=""
for ip in $(dig +short "$alb" | grep -E '^[0-9.]+$' || true); do
  if grep -qF "\"$ip:443\"" "$check/netlog.json"; then hit=$ip; fi
done
if [ -z "$hit" ]; then
  echo "$api did not reach the AWS load balancer in a test run, not opening the window" >&2
  exit 1
fi

echo "$api reaches AWS ($hit). Opening https://$frontend in the test profile $PROFILE"
open -na "Google Chrome" --args --user-data-dir="$PROFILE" --host-resolver-rules="$rules" "https://$frontend/"
