#!/bin/bash
# The Temporal CLI against production, with no port open on AWS: Session Manager
# forwards a port on this machine, through one of the ECS hosts, to the Temporal
# frontend (temporal-frontend.postiz.internal:7233).
#
#   scripts/temporal-cli.sh workflow list --limit 5   opens a tunnel, runs one command, closes it
#   scripts/temporal-cli.sh                           keeps a tunnel open on localhost:17233 for
#                                                     any temporal command (Ctrl-C closes it)
#   scripts/temporal-cli.sh --write workflow terminate -w <id> --reason "..."
#
# The frontend has no authorization: whoever reaches it can terminate, reset or
# delete any workflow. So a command given here must be one of the reads below
# unless --write comes first. That catches mistakes, it is no lock: the open
# tunnel takes anything.
# Local port 17233, not 7233: a Postiz or `temporal server start-dev` running on
# this machine must never reach production by accident.
# Needs the AWS CLI signed in with Session Manager access (AccountFullAccessRole;
# postiz-team-readonly and postiz-agent-readonly deny it), the Session Manager
# plugin and the Temporal CLI (brew install temporal).
set -euo pipefail
CLUSTER=${CLUSTER:-postiz-production}
FRONTEND=temporal-frontend.postiz.internal

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
session=(aws ssm start-session --target "$instance" --document-name AWS-StartPortForwardingSessionToRemoteHost)

if [ $# -eq 0 ]; then
  port=${LOCAL_PORT:-17233}
  echo "Temporal frontend on localhost:$port, every command allowed (Ctrl-C closes the tunnel). In another terminal:" >&2
  echo "  export TEMPORAL_ADDRESS=localhost:$port" >&2
  exec "${session[@]}" --parameters "host=$FRONTEND,portNumber=7233,localPortNumber=$port"
fi

# a random port, so that several commands can run at once
port=${LOCAL_PORT:-$((20000 + RANDOM % 20000))}
log=$(mktemp)
set -m # its own process group: the cleanup reaches the Session Manager plugin under the AWS CLI
"${session[@]}" --parameters "host=$FRONTEND,portNumber=7233,localPortNumber=$port" </dev/null >"$log" 2>&1 &
pid=$!
set +m
close() {
  kill -INT -- "-$pid" 2>/dev/null || true # like Ctrl-C: the plugin ends the session
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.3
  done
  kill -TERM -- "-$pid" 2>/dev/null || true
  rm -f "$log"
}
trap close EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for _ in $(seq 150); do # 30 s
  if grep -q 'Waiting for connections' "$log"; then
    TEMPORAL_ADDRESS=localhost:$port temporal "$@"
    exit
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    cat "$log" >&2
    exit 1
  fi
  sleep 0.2
done
echo "temporal-cli.sh: the tunnel did not open within 30 s" >&2
cat "$log" >&2
exit 1
