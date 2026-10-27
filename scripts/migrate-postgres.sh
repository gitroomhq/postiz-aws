#!/bin/bash
# Copy a Railway PostgreSQL database into RDS. Runs inside the ops task
# (docker/ops.Dockerfile), see docs/migration-runbook.md.
#
#   migrate-postgres.sh preflight main|temporal   read-only report, nothing written
#   migrate-postgres.sh copy      main|temporal   dump, restore, fix up, verify row counts
#   migrate-postgres.sh temporal-password         set the temporal role to the current secret
#                                                 (after bumping temporal_db_password_version)
#   migrate-postgres.sh connection-limits         re-apply the per-role connection caps below
#   migrate-postgres.sh init                      new installation, no Railway: create the roles
#                                                 and the temporal database with passwords from
#                                                 API_DB_PASSWORD, MCP_DB_PASSWORD, WORKER_DB_PASSWORD
#
# Both databases live on the one RDS instance:
#   main      Railway "Postgres"      -> database postiz,   owned by "api"
#   temporal  Railway "Postgres-NlPS" -> database temporal, owned by "temporal"
#
# Environment:
#   SOURCE_URL            Railway public URL of the source database, as the postgres superuser
#                         (Railway > service > Variables > DATABASE_PUBLIC_URL)
#   MAIN_ADMIN_URL        injected by the ops task (RDS master user, database postiz)
#   TEMPORAL_DB_PASSWORD  injected by the ops task (Terraform-generated login of "temporal")
#   JOBS                  parallel dump/restore workers, default 8
#   APP_ROLES             login roles the apps use on postiz, default "api mcp worker"
#   NUM_HISTORY_SHARDS    expected Temporal shard count, default 4 (Terraform temporal_num_history_shards)
#   TEMPORAL_SCHEMA       expected Temporal schema version, default 1.17 (what auto-setup 1.28.0 runs)
#   FORCE=1               turn the safety stops below into warnings (rehearsals while Railway runs)
#   WORKER_CONNECTIONS    cap for the worker role, default 64 (8 per process: up to 8 worker tasks)
#   MCP_CONNECTIONS       cap for the mcp role, default 100 (Prisma 8 + Mastra's pool per task)
#   TEMPORAL_CONNECTIONS  cap for the temporal role, default 400 (20 per Temporal task, deploys double them)
#
# Per-role caps: Postgres refuses a role's connection beyond its cap, so a
# runaway worker or Temporal can never take connections the API (role api,
# uncapped) or MCP need. On Railway, PgBouncer's per-user pools did this.
#
# Safety stops (preflight and copy): nothing else may be connected to the source,
# because a copy taken while Temporal or the apps still write is silently stale;
# and for temporal, the shard count and schema version must be the ones the AWS
# cluster runs, so the restored history is served by the same Temporal release.
#
# Ownership: RDS has no superuser, so instead of copying Railway's role flags,
# "api" owns every object in postiz and "mcp"/"worker" log in with their own
# passwords but act as "api" (ALTER ROLE ... SET role). Whatever the services
# create later (prisma db push, Mastra tables) is owned by "api", the role
# prisma db push runs as. Everything in temporal is owned by "temporal".
set -euo pipefail

mode=${1:-}
target=${2:-}
JOBS=${JOBS:-8}
APP_ROLES=${APP_ROLES:-"api mcp worker"}
ADMIN_URL=${MAIN_ADMIN_URL:?MAIN_ADMIN_URL missing, run this inside the ops task}

usage() {
  echo "usage: $0 preflight|copy main|temporal  |  $0 init  |  $0 temporal-password  |  $0 connection-limits" >&2
  exit 2
}

admin() { psql "$ADMIN_URL" -X -v ON_ERROR_STOP=1 "$@"; }

stop_unless_forced() {
  if [ "${FORCE:-0}" = 1 ]; then
    echo "WARNING (FORCE=1): $*" >&2
  else
    echo "STOP: $*" >&2
    exit 1
  fi
}

connection_limits() {
  admin -q <<SQL
alter role worker connection limit ${WORKER_CONNECTIONS:-64};
alter role mcp connection limit ${MCP_CONNECTIONS:-100};
SQL
  if [ -n "$(admin -Atc "select 1 from pg_roles where rolname = 'temporal'")" ]; then
    admin -qc "alter role temporal connection limit ${TEMPORAL_CONNECTIONS:-400}"
  fi
  admin -c "select rolname, rolconnlimit as connection_limit from pg_roles where rolname in ('api', 'mcp', 'worker', 'temporal') order by 1"
}

if [ "$mode" = connection-limits ]; then
  connection_limits
  exit 0
fi

if [ "$mode" = temporal-password ]; then
  : "${TEMPORAL_DB_PASSWORD:?TEMPORAL_DB_PASSWORD missing, run this inside the ops task}"
  admin -qc "alter role temporal with login password '$TEMPORAL_DB_PASSWORD'"
  echo "temporal role now uses the current secret; restart the temporal-* services"
  exit 0
fi

case "$mode:$target" in
  init:)
    DB=postiz
    OWNER_ROLE=$(echo "$APP_ROLES" | awk '{print $1}')
    : "${TEMPORAL_DB_PASSWORD:?TEMPORAL_DB_PASSWORD missing, run this inside the ops task}"
    ;;
  preflight:main | copy:main)
    DB=postiz
    OWNER_ROLE=$(echo "$APP_ROLES" | awk '{print $1}')
    ;;
  preflight:temporal | copy:temporal)
    DB=temporal
    OWNER_ROLE=temporal
    : "${TEMPORAL_DB_PASSWORD:?TEMPORAL_DB_PASSWORD missing, run this inside the ops task}"
    ;;
  *)
    usage
    ;;
esac
[ "$mode" = init ] || : "${SOURCE_URL:?set SOURCE_URL to the Railway DATABASE_PUBLIC_URL of the source database}"
# the admin URL with the target database name swapped in
TARGET_URL=$(python3 -c 'import sys; from urllib.parse import urlsplit, urlunsplit; u = urlsplit(sys.argv[1]); print(urlunsplit(u._replace(path="/" + sys.argv[2])))' "$ADMIN_URL" "$DB")

src() { psql "$SOURCE_URL" -X -v ON_ERROR_STOP=1 "$@"; }
dst() { psql "$TARGET_URL" -X -v ON_ERROR_STOP=1 "$@"; }

# exact row count of every table, one query per side
COUNT_SQL="select table_schema || '.' || table_name,
  (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text
  from information_schema.tables
  where table_type = 'BASE TABLE' and table_schema not in ('pg_catalog', 'information_schema')
  order by 1"

preflight() {
  echo "== source"
  src -c "select current_database() as db, pg_size_pretty(pg_database_size(current_database())) as size, current_setting('server_version') as version"
  src -c "select rolname, rolsuper, rolcreaterole, rolcreatedb, rolcanlogin, rolbypassrls from pg_roles where rolname !~ '^pg_' order by 1"
  src -c "select n.nspname as schema, pg_get_userbyid(c.relowner) as owner, count(*) as objects
          from pg_class c join pg_namespace n on n.oid = c.relnamespace
          where n.nspname not in ('pg_catalog', 'information_schema', 'pg_toast') group by 1, 2 order by 1, 2"
  src -c "select extname, extversion from pg_extension order by 1"
  src -c "select count(*) as open_connections from pg_stat_activity where datname = current_database() and pid <> pg_backend_pid()"
  if [ "$target" = temporal ]; then
    src -c "select db_name, curr_version from schema_version"
    src -c "select count(*) as history_shards from shards"
    src -c "select count(*) as running_workflows from current_executions where status = 1"
  fi

  echo "== safety checks"
  others=$(src -Atc "select count(*) from pg_stat_activity where datname = current_database() and pid <> pg_backend_pid()")
  if [ "$others" != 0 ]; then
    src -c "select usename, application_name, client_addr, state from pg_stat_activity where datname = current_database() and pid <> pg_backend_pid()"
    stop_unless_forced "$others other connections to the source. Stop every writer first (apps, workers, PgBouncer, the four Temporal services, anything else using this database)"
  else
    echo "no other connections to the source: writers are stopped"
  fi
  if [ "$target" = temporal ]; then
    shards=$(src -Atc "select count(*) from shards")
    [ "$shards" = "${NUM_HISTORY_SHARDS:-4}" ] || stop_unless_forced "source has $shards history shards, the AWS cluster is configured for ${NUM_HISTORY_SHARDS:-4} (temporal_num_history_shards)"
    version=$(src -Atc "select curr_version from schema_version limit 1")
    [ "$version" = "${TEMPORAL_SCHEMA:-1.17}" ] || stop_unless_forced "source schema is $version, expected ${TEMPORAL_SCHEMA:-1.17}: Railway is not running the Temporal release AWS will run"
    echo "shards $shards and schema $version match the AWS cluster"
  fi

  echo "== target ($DB)"
  admin -c "select current_setting('server_version') as version"
  if [ -n "$(admin -Atc "select 1 from pg_database where datname = '$DB'")" ]; then
    n=$(dst -Atc "select count(*) from pg_tables where schemaname not in ('pg_catalog', 'information_schema')")
    if [ "$n" != 0 ]; then
      echo "database $DB already has $n tables: restore into an empty database only" >&2
      exit 1
    fi
    echo "database $DB exists and is empty"
  else
    echo "database $DB does not exist yet, copy creates it"
  fi
}

prepare_main() {
  local sql
  sql=$(mktemp)
  chmod 600 "$sql"
  {
    echo "set createrole_self_grant = 'set, inherit';"
    for role in $APP_ROLES; do
      if [ "$mode" = init ]; then
        # new installation: the password from <ROLE>_DB_PASSWORD
        var="$(echo "$role" | tr '[:lower:]' '[:upper:]')_DB_PASSWORD"
        hash="${!var:-}"
        if [ -z "$hash" ]; then echo "set $var" >&2; exit 1; fi
      else
        # same password verifier as on Railway, so the DATABASE_URLs keep working
        hash=$(src -Atc "select rolpassword from pg_authid where rolname = '$role'")
        if [ -z "$hash" ]; then echo "role $role not found on the source" >&2; exit 1; fi
      fi
      echo "do \$\$ begin if not exists (select from pg_roles where rolname = '$role') then create role \"$role\" login; end if; end \$\$;"
      # only LOGIN + password: superuser flags cannot be set on RDS, new roles have none
      echo "alter role \"$role\" with login password '$hash';"
    done
    echo "grant connect, create, temporary on database \"$DB\" to \"$OWNER_ROLE\";"
    echo "grant all on schema public to \"$OWNER_ROLE\";"
    for role in $APP_ROLES; do
      [ "$role" = "$OWNER_ROLE" ] && continue
      echo "grant \"$OWNER_ROLE\" to \"$role\";"
      echo "alter role \"$role\" set role = '$OWNER_ROLE';"
    done
  } > "$sql"
  dst -q -f "$sql"
  rm -f "$sql"
  connection_limits
  echo "roles ready: $APP_ROLES (owner: $OWNER_ROLE)"
}

prepare_temporal() {
  admin -q <<SQL
set createrole_self_grant = 'set, inherit';
do \$\$ begin if not exists (select from pg_roles where rolname = 'temporal') then create role temporal login; end if; end \$\$;
alter role temporal with login password '$TEMPORAL_DB_PASSWORD';
SQL
  if [ -z "$(admin -Atc "select 1 from pg_database where datname = 'temporal'")" ]; then
    admin -qc "create database temporal owner temporal"
  fi
  admin -qc "alter role temporal connection limit ${TEMPORAL_CONNECTIONS:-400}"
  echo "role temporal and database temporal ready"
}

copy_extensions() {
  # pg_restore would create them as the restoring role; some need rds_superuser
  for ext in $(src -Atc "select extname from pg_extension where extname <> 'plpgsql'"); do
    dst -qc "create extension if not exists \"$ext\""
    echo "extension $ext"
  done
}

copy() {
  preflight
  local dir="/work/${target}-$(date +%Y%m%d-%H%M%S)"
  if [ "$target" = main ]; then prepare_main; else prepare_temporal; fi
  copy_extensions

  echo "== dump to $dir ($JOBS jobs)"
  time pg_dump "$SOURCE_URL" --format=directory --jobs="$JOBS" --no-owner --no-privileges --compress=3 --file="$dir"
  du -sh "$dir"

  echo "== restore as $OWNER_ROLE"
  # extensions were created above by the admin user; the restoring role may not
  # own them (or the public schema), so their entries and comments are skipped
  pg_restore --list "$dir" | grep -v -E ' EXTENSION - | COMMENT - EXTENSION | COMMENT - SCHEMA public ' > "$dir.toc"
  set +e
  time pg_restore --dbname="$TARGET_URL" --jobs="$JOBS" --no-owner --no-privileges --role="$OWNER_ROLE" \
    --use-list="$dir.toc" "$dir" 2> "$dir.restore.log"
  status=$?
  set -e
  if [ $status -ne 0 ]; then
    echo "pg_restore reported errors (full log: $dir.restore.log):" >&2
    grep -i error "$dir.restore.log" | head -30 >&2
  fi

  if [ "$target" = temporal ]; then
    # Temporal keys its schema version row by database name (Railway: "railway").
    # Without this, auto-setup re-runs every migration and the frontend crash-loops.
    dst -c "update schema_version set db_name = current_database() where db_name <> current_database() returning db_name, curr_version"
    running_src=$(src -Atc "select count(*) from current_executions where status = 1")
    running_dst=$(dst -Atc "select count(*) from current_executions where status = 1")
    [ "$running_src" = "$running_dst" ] || { echo "running workflows differ: source $running_src, target $running_dst" >&2; exit 1; }
    echo "running workflows: $running_dst on both sides"
  fi

  echo "== analyze"
  dst -qc "set client_min_messages = error; analyze"

  echo "== verify row counts"
  src -AtF $'\t' -c "$COUNT_SQL" > "$dir.source-counts"
  dst -AtF $'\t' -c "$COUNT_SQL" > "$dir.target-counts"
  if diff "$dir.source-counts" "$dir.target-counts" > "$dir.count-diff"; then
    echo "OK: $(wc -l < "$dir.source-counts") tables, identical row counts"
  else
    echo "ROW COUNT MISMATCH (source < > target):" >&2
    cat "$dir.count-diff" >&2
    exit 1
  fi
  [ $status -eq 0 ] || { echo "row counts match but pg_restore logged errors, read $dir.restore.log before going on" >&2; exit 1; }
}

# new installation without Railway: roles and the temporal database, no data;
# the db-push task then creates the postiz tables and Temporal its schema
init() {
  prepare_main
  prepare_temporal
  echo "ready: set each service's DATABASE_URL to postgresql://<role>:<password>@<host>:5432/postiz?connection_limit=8&application_name=<role>"
}

case "$mode" in
  preflight) preflight ;;
  copy) copy ;;
  init) init ;;
  *) usage ;;
esac
