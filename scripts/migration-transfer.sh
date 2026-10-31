#!/bin/bash
# Moves the Railway data to AWS without opening a port on either side, see
# docs/migration-runbook.md (A5b, A6, B6 to B8). A temporary service inside the
# Railway project (the toolbox, docker/ops.Dockerfile) reads the two databases
# and the Temporal index over Railway's private network and uploads the files to
# the private migration bucket with short-lived, upload-only keys; the AWS ops
# task downloads them through the VPC and restores them.
#
#   migration-transfer.sh keys               your machine: fresh upload keys on the toolbox (valid
#                                            one hour; Railway restarts the toolbox with them)
#   migration-transfer.sh preflight          toolbox: read-only report on the sources and the keys,
#                                            ends with "ready to export" once the writers are stopped
#   migration-transfer.sh export             toolbox: dump main, temporal and the index in parallel,
#                                            upload, print the import command
#   migration-transfer.sh upload RUN         toolbox: upload an export again (after fresh keys)
#   migration-transfer.sh import RUN DIGEST  ops task: download, check every file, restore in parallel
#
# The digest export prints covers every file of the run: import refuses anything
# else, so the upload keys cannot slip other data into the restore. Each side
# deletes its copy once it is done with it; the bucket keeps a run for 7 days.
#
# Environment:
#   SOURCE_MAIN_URL      toolbox: ${{Postgres.DATABASE_URL}}
#   SOURCE_TEMPORAL_URL  toolbox: ${{Postgres-NlPS.DATABASE_URL}}
#   SOURCE_ES_URL        toolbox: http://elastic:${{Elasticsearch.ELASTIC_PASSWORD}}@${{Elasticsearch.RAILWAY_PRIVATE_DOMAIN}}:9200
#   MIGRATION_BUCKET     toolbox: terraform output migration_bucket (the ops task has it)
#   AWS_REGION           toolbox: the stack's region (the ops task has it)
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN, AWS_KEYS_EXPIRE
#                        toolbox: set by keys (the ops task reads the bucket with its role)
#   ONLY                 parts to move, default "main temporal es" (import: the parts of the run)
#   ES_INDEX             Temporal visibility index, default temporal_visibility_v1_dev
#   FORCE=1              passed on: rehearsals while Railway still runs (never in the cutover window)
#   WORK                 local directory, default /work
#   TOOLBOX_SERVICE      the Railway service keys writes to, default migration-toolbox
#   S3_ENDPOINT_URL      an S3-compatible endpoint instead of AWS (local tests)
#
# keys needs Terraform initialised in environments/production, an AWS session
# allowed to assume the upload role, and `railway link` to the toolbox's project
# and environment.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
mode=${1:-}
WORK=${WORK:-/work}
ES_INDEX=${ES_INDEX:-temporal_visibility_v1_dev}
TOOLBOX_SERVICE=${TOOLBOX_SERVICE:-migration-toolbox}
PARTS="main temporal es"

usage() {
  echo "usage: $0 keys | preflight | export | upload RUN | import RUN DIGEST" >&2
  exit 2
}

need() {
  local v missing=""
  for v in "$@"; do [ -n "${!v:-}" ] || missing="$missing $v"; done
  [ -z "$missing" ] || { echo "missing:$missing (see the top of $0)" >&2; exit 1; }
}

# the bucket, through AWS or S3_ENDPOINT_URL
bucket() { aws ${S3_ENDPOINT_URL:+--endpoint-url "$S3_ENDPOINT_URL"} "$@"; }

source_var() {
  case $1 in
    main) echo SOURCE_MAIN_URL ;;
    temporal) echo SOURCE_TEMPORAL_URL ;;
    es) echo SOURCE_ES_URL ;;
  esac
}

check_parts() {
  local part
  for part in $ONLY; do
    case " $PARTS " in
      *" $part "*) ;;
      *) echo "unknown part $part (main, temporal, es)" >&2; exit 2 ;;
    esac
  done
}

# the file each export writes last
exported() {
  case $1 in
    main | temporal) [ -f "$dir/$1/source-counts" ] ;;
    es) [ -f "$dir/$1/meta.json" ] ;;
  esac
}

export_main() { SOURCE_URL=$SOURCE_MAIN_URL "$here/migrate-postgres.sh" export main "$dir/main"; }
export_temporal() { SOURCE_URL=$SOURCE_TEMPORAL_URL "$here/migrate-postgres.sh" export temporal "$dir/temporal"; }
export_es() { python3 "$here/es-copy-index.py" --index "$ES_INDEX" --export "$dir/es"; }
import_main() { "$here/migrate-postgres.sh" import main "$dir/main"; }
import_temporal() { "$here/migrate-postgres.sh" import temporal "$dir/temporal"; }
import_es() { python3 "$here/es-copy-index.py" --import "$dir/es"; }

# runs <step>_<part> for every part at once, each output line prefixed with [part]
in_parallel() {
  local step=$1 i failed=0
  local -a parts pids
  read -r -a parts <<< "$ONLY"
  for i in "${!parts[@]}"; do
    "${step}_${parts[$i]}" > >(sed -u "s/^/[${parts[$i]}] /") 2>&1 &
    pids[i]=$!
  done
  for i in "${!parts[@]}"; do
    if wait "${pids[$i]}"; then
      echo "[${parts[$i]}] $step done"
    else
      echo "[${parts[$i]}] $step FAILED"
      failed=1
    fi
  done
  return "$failed"
}

# $1: what to run once fresh keys are in
check_keys() {
  if [ -n "${S3_ENDPOINT_URL:-}" ]; then return 0; fi
  need AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  if ! aws sts get-caller-identity > /dev/null 2>&1; then
    echo "the upload keys are expired or wrong: run migration-transfer.sh keys on your machine, reconnect, then $1" >&2
    exit 1
  fi
  if [ -n "${AWS_KEYS_EXPIRE:-}" ]; then
    echo "upload keys valid for $(( ($(date -d "$AWS_KEYS_EXPIRE" +%s) - $(date +%s)) / 60 )) more minutes"
  fi
}

# your machine: assume the upload role and hand its keys to the toolbox, without printing them
keys() {
  local role out id secret token expires
  role=$(terraform -chdir="$here/../environments/production" output -raw migration_upload_role_arn)
  # your CLI session is itself a role, and a role assumed from a role lasts one hour at most
  out=$(aws sts assume-role --role-arn "$role" --role-session-name "railway-toolbox-$(date +%Y%m%d%H%M%S)" \
    --duration-seconds 3600 --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken,Expiration]' --output text)
  read -r id secret token expires <<< "$out"
  # the Railway CLI takes values only as arguments, so for a moment these keys sit
  # in its command line: acceptable for one-hour keys that can only upload
  railway variables --service "$TOOLBOX_SERVICE" --set "AWS_ACCESS_KEY_ID=$id" --set "AWS_SECRET_ACCESS_KEY=$secret" \
    --set "AWS_SESSION_TOKEN=$token" --set "AWS_KEYS_EXPIRE=$expires" > /dev/null
  echo "upload keys set on $TOOLBOX_SERVICE, valid until $expires."
  echo "Railway redeploys the toolbox with them (deploy the change in the dashboard if it waits), then:"
  echo "  railway ssh --service $TOOLBOX_SERVICE"
}

preflight() {
  local part var docs running status=0
  ONLY=${ONLY:-$PARTS}
  check_parts
  for part in $ONLY; do
    var=$(source_var "$part")
    need "$var"
    echo "=== $part"
    case $part in
      main | temporal) SOURCE_URL=${!var} "$here/migrate-postgres.sh" preflight "$part" || status=1 ;;
      es)
        docs=$(curl -fsS "$SOURCE_ES_URL/$ES_INDEX/_count" | jq -e .count) || status=1
        running=$(curl -fsS -H 'Content-Type: application/json' "$SOURCE_ES_URL/$ES_INDEX/_count" \
          -d '{"query":{"term":{"ExecutionStatus":"Running"}}}' | jq -e .count) || status=1
        echo "$ES_INDEX: ${docs:-?} documents, ${running:-?} running workflows"
        ;;
    esac
  done
  echo "=== upload keys"
  (check_keys "migration-transfer.sh preflight") || status=1
  if [ "$status" = 0 ]; then echo "=== ready to export"; else echo "=== not ready, see above"; fi
  return "$status"
}

export_run() {
  local part
  ONLY=${ONLY:-$PARTS}
  check_parts
  need MIGRATION_BUCKET
  for part in $ONLY; do need "$(source_var "$part")"; done
  check_keys "migration-transfer.sh export"
  run=$(date -u +%Y%m%d-%H%M%S)
  dir=$WORK/$run
  mkdir -p "$dir"
  echo "run $run: exporting $ONLY into $dir"
  if ! in_parallel export; then
    rm -rf "$dir"
    echo "export failed: nothing uploaded, partial files deleted" >&2
    exit 1
  fi
  upload_run
}

upload_run() {
  local part parts="" digest
  [ -d "$dir" ] || { echo "no export in $dir" >&2; exit 1; }
  need MIGRATION_BUCKET
  for part in $PARTS; do
    [ -d "$dir/$part" ] || continue
    exported "$part" || { echo "the $part export in $dir did not finish, export again" >&2; exit 1; }
    parts="$parts $part"
  done
  [ -n "$parts" ] || { echo "nothing exported in $dir" >&2; exit 1; }
  check_keys "migration-transfer.sh upload $run"

  echo "== checksums"
  for part in $parts; do
    (cd "$dir/$part" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
  done
  (cd "$dir" && for part in $parts; do sha256sum "$part/SHA256SUMS"; done > MANIFEST)
  digest=$(sha256sum "$dir/MANIFEST" | cut -c1-16)

  echo "== upload $(du -sh "$dir" | cut -f1) to s3://$MIGRATION_BUCKET/$run/"
  for part in $parts; do
    bucket s3 cp --recursive --only-show-errors "$dir/$part" "s3://$MIGRATION_BUCKET/$run/$part"
  done
  # last: a run without MANIFEST is incomplete
  bucket s3 cp --only-show-errors "$dir/MANIFEST" "s3://$MIGRATION_BUCKET/$run/MANIFEST"
  rm -rf "$dir"
  echo "$run $digest" >> "$WORK/uploaded-runs"
  echo "uploaded, local copy deleted. In the AWS ops task (also in $WORK/uploaded-runs):"
  echo "  migration-transfer.sh import $run $digest"
}

import_run() {
  local digest=$1 part parts
  need MIGRATION_BUCKET
  dir=$WORK/import-$run
  rm -rf "$dir"
  mkdir -p "$dir"
  # files that fail a check are deleted; a failed restore keeps its logs to read
  trap 'rm -rf "$dir"' EXIT
  if ! bucket s3 cp --only-show-errors "s3://$MIGRATION_BUCKET/$run/MANIFEST" "$dir/MANIFEST"; then
    echo "no s3://$MIGRATION_BUCKET/$run/MANIFEST: that run was not uploaded completely" >&2
    exit 1
  fi
  if [ "$(sha256sum "$dir/MANIFEST" | cut -c1-16)" != "$digest" ]; then
    echo "STOP: s3://$MIGRATION_BUCKET/$run is not the run export printed $digest for" >&2
    exit 1
  fi
  parts=$(sed 's|^[0-9a-f]*  \(.*\)/SHA256SUMS$|\1|' "$dir/MANIFEST")
  for part in $parts; do
    bucket s3 cp --only-show-errors "s3://$MIGRATION_BUCKET/$run/$part/SHA256SUMS" "$dir/$part/SHA256SUMS"
  done
  (cd "$dir" && sha256sum --quiet -c MANIFEST)

  # the run may hold nothing but the listed files: anything else was not uploaded by the export
  for part in $parts; do
    echo "$run/$part/SHA256SUMS"
    sed "s|^[0-9a-f]*  \./|$run/$part/|" "$dir/$part/SHA256SUMS"
  done | { cat; echo "$run/MANIFEST"; } | sort > "$dir/expected-keys"
  bucket s3api list-objects-v2 --bucket "$MIGRATION_BUCKET" --prefix "$run/" --query 'Contents[].Key' --output text \
    | tr '\t' '\n' | sort > "$dir/keys"
  if ! diff "$dir/expected-keys" "$dir/keys" > /dev/null; then
    echo "STOP: s3://$MIGRATION_BUCKET/$run holds files the export did not list:" >&2
    diff "$dir/expected-keys" "$dir/keys" >&2 || true
    exit 1
  fi

  echo "== download" $parts
  for part in $parts; do
    bucket s3 cp --recursive --only-show-errors "s3://$MIGRATION_BUCKET/$run/$part" "$dir/$part"
    (cd "$dir/$part" && sha256sum --quiet -c SHA256SUMS)
  done
  echo "every file matches the export ($(du -sh "$dir" | cut -f1))"

  ONLY=${ONLY:-$(echo $parts)}
  check_parts
  trap - EXIT
  if ! in_parallel import; then
    echo "import failed; the files and restore logs stay in $dir until the next try. Empty the targets (migrate-postgres.sh reset) before it" >&2
    exit 1
  fi
  rm -rf "$dir"
  echo "import done, local copy deleted"
}

case "$mode" in
  keys) keys ;;
  preflight) preflight ;;
  export) export_run ;;
  upload)
    run=${2:-}
    [ -n "$run" ] || usage
    dir=$WORK/$run
    upload_run
    ;;
  import)
    run=${2:-}
    [ -n "$run" ] && [ -n "${3:-}" ] || usage
    import_run "$3"
    ;;
  *) usage ;;
esac
