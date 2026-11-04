#!/bin/bash
# The Temporal CLI against production, with no port open on AWS: Session Manager
# forwards a port on this machine, through one of the ECS hosts, into the VPC.
#
#   scripts/temporal-cli.sh workflow list --limit 5   opens a tunnel, runs one command, closes it
#   scripts/temporal-cli.sh                           keeps a read-only tunnel open on
#                                                     localhost:17233 (Ctrl-C closes it)
#   scripts/temporal-cli.sh --write workflow terminate -w <id> --reason "..."
#   scripts/temporal-cli.sh --write                   keeps a tunnel open for any command
#
# Reads go to the read-only proxy (temporal-readonly.postiz.internal:7233, see
# environments/production/temporal-readonly.tf), through the Session Manager
# document postiz-team-temporal-readonly, whose host and port are fixed. The proxy
# passes only read calls and answers anything else with 403 (Forbidden), whoever
# asks. This works with AccountFullAccessRole and with postiz-team-readonly.
#
# --write tunnels straight to the frontend (temporal-frontend.postiz.internal:7233),
# which has no authorization: whoever reaches it can terminate, reset or delete any
# workflow. Only an admin sign-in (AccountFullAccessRole) may open that tunnel.
# A command given here must also be one of the reads below unless --write comes
# first; that catches mistakes before the proxy refuses them.
# Local port 17233, not 7233: a Postiz or `temporal server start-dev` running on
# this machine must never reach production by accident.
# Needs the AWS CLI signed in (aws login), the Session Manager plugin and the
# Temporal CLI (brew install temporal). postiz-agent-readonly denies Session Manager.
set -euo pipefail
CLUSTER=${CLUSTER:-postiz-production}
FRONTEND=temporal-frontend.postiz.internal
READONLY_DOCUMENT=postiz-team-temporal-readonly

write=false
if [ "${1:-}" = --write ]; then
  write=true
  shift
fi

# help needs no server
[ "${1:-}" = help ] && exec temporal "$@"
for arg in "$@"; do
  case "$arg" in -h | --help) exec temporal "$@" ;; esac
done

if [ $# -gt 0 ] && [ "$write" = false ]; then
  # the command is the words before the first flag; a positional argument makes it no match
  cmd=
  for arg in "$@"; do
    case "$arg" in -*) break ;; esac
    cmd="${cmd:+$cmd }$arg"
  done
  case "$cmd" in
    "workflow list" | "workflow count" | "workflow describe" | "workflow show" | "workflow result" | \
      "workflow stack" | "workflow query" | "workflow metadata" | "workflow trace" | \
      "workflow update describe" | "workflow update result" | \
      "schedule list" | "schedule describe" | "batch list" | "batch describe" | \
      "task-queue describe" | "task-queue list-partition" | "task-queue get-build-ids" | \
      "task-queue get-build-id-reachability" | "task-queue versioning get-rules" | "task-queue config get" | \
      "worker list" | "worker describe" | "worker deployment list" | "worker deployment describe" | \
      "worker deployment describe-version" | \
      "operator cluster health" | "operator cluster describe" | "operator cluster list" | \
      "operator cluster system" | "operator namespace list" | "operator namespace describe" | \
      "operator search-attribute list" | "operator nexus endpoint list" | "operator nexus endpoint get") ;;
    *)
      echo "temporal-cli.sh: 'temporal ${cmd:-$1}' is not one of the read commands (command first, then flags)." >&2
      echo "To change Temporal, put --write first: $0 --write $*" >&2
      exit 2
      ;;
  esac
fi

hosts=$(aws ecs list-container-instances --cluster "$CLUSTER" --status ACTIVE \
  --query containerInstanceArns --output text)
if [ -z "$hosts" ] || [ "$hosts" = None ]; then
  echo "temporal-cli.sh: $CLUSTER has no active ECS host" >&2
  exit 1
fi
# shellcheck disable=SC2086 # one argument per ARN
instance=$(aws ecs describe-container-instances --cluster "$CLUSTER" --container-instances $hosts \
  --query 'containerInstances[?agentConnected].ec2InstanceId | [0]' --output text)
if [ "$write" = true ]; then
  # straight to the frontend: every command, admin sign-in only
  session=(aws ssm start-session --target "$instance" --document-name AWS-StartPortForwardingSessionToRemoteHost)
  forward() { echo "host=$FRONTEND,portNumber=7233,localPortNumber=$1"; }
  what="Temporal frontend, every command allowed"
else
  # the read-only proxy: the document fixes host and port, only the local port is ours
  session=(aws ssm start-session --target "$instance" --document-name "$READONLY_DOCUMENT")
  forward() { echo "localPortNumber=$1"; }
  what="Temporal through the read-only proxy, reads only"
fi

hint() { # why a tunnel or a command failed, from its output
  if grep -q 'AccessDenied' "$1" && [ "$write" = true ]; then
    echo "temporal-cli.sh: --write tunnels straight to the frontend and needs an admin sign-in (AccountFullAccessRole). Reads work without --write." >&2
  elif grep -q 'AccessDenied' "$1"; then
    echo "temporal-cli.sh: this sign-in may not open the read-only tunnel (postiz-team-readonly or AccountFullAccessRole can)." >&2
  elif grep -q '403 (Forbidden)' "$1"; then
    echo "temporal-cli.sh: the read-only proxy refused that call: it passes reads only. Changes need --write and an admin sign-in." >&2
  fi
}

if [ $# -eq 0 ]; then
  port=${LOCAL_PORT:-17233}
  echo "$what, on localhost:$port (Ctrl-C closes the tunnel). In another terminal:" >&2
  echo "  export TEMPORAL_ADDRESS=localhost:$port" >&2
  exec "${session[@]}" --parameters "$(forward "$port")"
fi

# a random port, so that several commands can run at once
port=${LOCAL_PORT:-$((20000 + RANDOM % 20000))}
log=$(mktemp)
out=$(mktemp)
set -m # its own process group: the cleanup reaches the Session Manager plugin under the AWS CLI
"${session[@]}" --parameters "$(forward "$port")" </dev/null >"$log" 2>&1 &
pid=$!
set +m
close() {
  kill -INT -- "-$pid" 2>/dev/null || true # like Ctrl-C: the plugin ends the session
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.3
  done
  kill -TERM -- "-$pid" 2>/dev/null || true
  rm -f "$log" "$out"
}
trap close EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for _ in $(seq 150); do # 30 s
  if grep -q 'Waiting for connections' "$log"; then
    # stdout untouched; stderr passes through as it comes, and a copy tells the
    # hint what happened (a pipe, not >(...): macOS runs this with bash 3.2)
    rc=0
    { TEMPORAL_ADDRESS=localhost:$port temporal "$@" 2>&1 1>&3 3>&- | tee "$out" 1>&2 3>&-; } 3>&1 || rc=$?
    [ "$rc" -eq 0 ] || hint "$out"
    exit "$rc"
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    cat "$log" >&2
    hint "$log"
    exit 1
  fi
  sleep 0.2
done
echo "temporal-cli.sh: the tunnel did not open within 30 s" >&2
cat "$log" >&2
exit 1
