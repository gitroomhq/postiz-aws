#!/bin/bash
# psql against production as the read-only role, from this machine, with no port
# open on AWS: the Session Manager tunnel postiz-team-postgres-readonly
# (environments/production/team-tunnels.tf) forwards a local port through one of
# the ECS hosts to PostgreSQL on postiz-production-main, and nowhere else.
#
#   scripts/psql-readonly.sh                                    an interactive psql session
#   scripts/psql-readonly.sh -c 'select count(*) from "Post"'   one query (any psql arguments)
#   scripts/psql-readonly.sh --tunnel                           keeps the tunnel open on
#                                                               localhost:15432 for another client
#
# It signs in as "readonly" with a 15-minute IAM token (aws rds generate-db-auth-token),
# so there is no password. That role reads every table except the columns that hold
# credentials (on those tables SELECT * fails, so name the columns); transactions are
# read-only, statements stop after 60 s, and it gets 5 connections (db-readers.tf,
# migrate-postgres.sh readonly-role). Local port 15432, not 5432: a PostgreSQL on this
# machine must never be mistaken for production.
# Needs the AWS CLI signed in (aws login) as postiz-team-readonly or AccountFullAccessRole,
# the Session Manager plugin and psql (brew install libpq).
set -euo pipefail
REGION=${REGION:-us-east-2}
CLUSTER=${CLUSTER:-postiz-production}
DB_INSTANCE=${DB_INSTANCE:-postiz-production-main}
DOCUMENT=postiz-team-postgres-readonly
DB_USER=readonly
DB_NAME=postiz

tunnel_only=false
if [ "${1:-}" = --tunnel ]; then
  tunnel_only=true
  shift
fi

if ! command -v session-manager-plugin >/dev/null; then
  echo "psql-readonly.sh: install the Session Manager plugin first" >&2
  exit 1
fi
if [ "$tunnel_only" = false ] && ! command -v psql >/dev/null; then
  echo "psql-readonly.sh: psql not found (brew install libpq, then put \$(brew --prefix libpq)/bin on PATH)" >&2
  exit 1
fi

host=$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$DB_INSTANCE" \
  --query 'DBInstances[0].Endpoint.Address' --output text)
hosts=$(aws ecs list-container-instances --region "$REGION" --cluster "$CLUSTER" --status ACTIVE \
  --query containerInstanceArns --output text)
if [ -z "$hosts" ] || [ "$hosts" = None ]; then
  echo "psql-readonly.sh: $CLUSTER has no active ECS host" >&2
  exit 1
fi
# shellcheck disable=SC2086 # one argument per ARN
instance=$(aws ecs describe-container-instances --region "$REGION" --cluster "$CLUSTER" --container-instances $hosts \
  --query 'containerInstances[?agentConnected].ec2InstanceId | [0]' --output text)
# the document fixes host and port, only the local port is ours
session=(aws ssm start-session --region "$REGION" --target "$instance" --document-name "$DOCUMENT")

# The token and TLS name the real host; hostaddr sends the connection into the tunnel.
conninfo() { echo "host=$host hostaddr=127.0.0.1 port=$1 dbname=$DB_NAME user=$DB_USER sslmode=require application_name=psql-readonly"; }
token_command="aws rds generate-db-auth-token --region $REGION --hostname $host --port 5432 --username $DB_USER"

if [ "$tunnel_only" = true ]; then
  port=${LOCAL_PORT:-15432}
  echo "PostgreSQL as $DB_USER on localhost:$port (Ctrl-C closes the tunnel). In another terminal:" >&2
  echo "  PGPASSWORD=\"\$($token_command)\" psql \"$(conninfo "$port")\"" >&2
  echo "Other clients: host 127.0.0.1, port $port, database $DB_NAME, user $DB_USER, SSL required," >&2
  echo "password from: $token_command (valid 15 minutes; an open connection stays open)." >&2
  exec "${session[@]}" --parameters "localPortNumber=$port"
fi

# a fresh token before the tunnel: a sign-in problem shows up here, not as a password prompt
password=$($token_command)

# a random port, so that several sessions can run at once
port=${LOCAL_PORT:-$((20000 + RANDOM % 20000))}
log=$(mktemp)
set -m # its own process group: the cleanup reaches the Session Manager plugin under the AWS CLI
"${session[@]}" --parameters "localPortNumber=$port" </dev/null >"$log" 2>&1 &
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
    rc=0
    PGPASSWORD=$password psql "$(conninfo "$port")" "$@" || rc=$?
    exit "$rc"
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    cat "$log" >&2
    if grep -q 'AccessDenied' "$log"; then
      echo "psql-readonly.sh: this sign-in may not open the database tunnel (postiz-team-readonly or AccountFullAccessRole can)." >&2
    fi
    exit 1
  fi
  sleep 0.2
done
echo "psql-readonly.sh: the tunnel did not open within 30 s" >&2
cat "$log" >&2
exit 1
