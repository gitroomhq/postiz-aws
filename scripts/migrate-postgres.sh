#!/bin/bash
# Move a Railway PostgreSQL database into RDS, see docs/migration-runbook.md.
#
# The runbook's way opens no port anywhere: export runs in a temporary service
# inside the Railway project, import in the AWS ops task (docker/ops.Dockerfile),
# and scripts/migration-transfer.sh carries the files between them through the
# private migration bucket. copy does both on one machine that reaches both sides.
#
#   migrate-postgres.sh preflight main|temporal       read-only report of the side(s) this machine
#                                                     reaches (SOURCE_URL, MAIN_ADMIN_URL)
#   migrate-postgres.sh export    main|temporal DIR   source side: dump, extensions, row counts and,
#                                                     for main, the app roles' password verifiers into DIR
#   migrate-postgres.sh import    main|temporal DIR   AWS side: roles, restore DIR, fix up, verify the
#                                                     row counts the export recorded
#   migrate-postgres.sh copy      main|temporal       export to $WORK and import, in one go
#   migrate-postgres.sh temporal-password             set the temporal role to the current secret
#                                                     (after bumping temporal_db_password_version)
#   migrate-postgres.sh connection-limits             re-apply the per-role connection caps below
#   migrate-postgres.sh readonly-role                 create or refresh "readonly", the team's login for
#                                                     queries from CloudShell: IAM token sign-in, no
#                                                     password, credential columns hidden; run it again
#                                                     after schema changes
#   migrate-postgres.sh init                          no data from Railway (new installation, test run):
#                                                     create the roles and the temporal database, each
#                                                     role with the password of the app DATABASE_URL the
#                                                     ops task injects (API_/MCP_/WORKER_DATABASE_URL),
#                                                     or of API_DB_PASSWORD, MCP_DB_PASSWORD, WORKER_DB_PASSWORD
#   migrate-postgres.sh reset                         empty postiz, temporal and the Temporal search index
#                                                     on AWS, keeping the logins (around the test run on
#                                                     empty databases); refuses while anything is connected
#
# Both databases live on the one RDS instance:
#   main      Railway "Postgres"      -> database postiz,   owned by "api"
#   temporal  Railway "Postgres-NlPS" -> database temporal, owned by "temporal"
#
# Environment:
#   SOURCE_URL            the source database as the postgres superuser (preflight, export, copy;
#                         on Railway the service's DATABASE_URL, migration-transfer.sh sets it)
#   MAIN_ADMIN_URL        injected by the ops task (RDS master user, database postiz)
#   TEMPORAL_DB_PASSWORD  injected by the ops task (Terraform-generated login of "temporal")
#   TARGET_ES_URL         injected by the ops task (reset deletes the Temporal index there)
#   ES_INDEX              Temporal visibility index, default temporal_visibility_v1_dev
#   JOBS                  parallel dump/restore workers, default 8
#   WORK                  where copy keeps its dump, default /work
#   APP_ROLES             login roles the apps use on postiz, default "api mcp worker"
#   NUM_HISTORY_SHARDS    expected Temporal shard count, default 4 (Terraform temporal_num_history_shards)
#   TEMPORAL_SCHEMA       expected Temporal schema version, default 1.17 (what auto-setup 1.28.0 runs)
#   FORCE=1               turn the safety stops below into warnings (rehearsals while Railway runs)
#   WORKER_CONNECTIONS    cap for the worker role, default 64 (8 per process: up to 8 worker tasks)
#   MCP_CONNECTIONS       cap for the mcp role, default 100 (Prisma 8 + Mastra's pool per task)
#   TEMPORAL_CONNECTIONS  cap for the temporal role, default 400 (20 per Temporal task, deploys double them)
#   READONLY_CONNECTIONS  cap for the readonly role, default 5
#   READONLY_STATEMENT_TIMEOUT  longest statement the readonly role may run, default 60s
#
# Per-role caps: Postgres refuses a role's connection beyond its cap, so a
# runaway worker or Temporal can never take connections the API (role api,
# uncapped) or MCP need. On Railway, PgBouncer's per-user pools did this.
#
# Safety stops: nothing else may be connected to the source (preflight, export),
# because a copy taken while Temporal or the apps still write is silently stale;
# for temporal, the shard count and schema version must be the ones the AWS
# cluster runs, so the restored history is served by the same Temporal release;
# and the restored row counts must be the ones recorded at export (import).
#
# Ownership: RDS has no superuser, so instead of copying Railway's role flags,
# "api" owns every object in postiz and "mcp"/"worker" log in with their own
# passwords but act as "api" (ALTER ROLE ... SET role). Whatever the services
# create later (prisma db push, Mastra tables) is owned by "api", the role
# prisma db push runs as. Everything in temporal is owned by "temporal".
set -euo pipefail

mode=${1:-}
target=${2:-}
dir=${3:-}
JOBS=${JOBS:-8}
APP_ROLES=${APP_ROLES:-"api mcp worker"}
ADMIN_URL=${MAIN_ADMIN_URL:-}

usage() {
  echo "usage: $0 preflight|copy main|temporal  |  $0 export|import main|temporal DIR  |  $0 init  |  $0 reset  |  $0 temporal-password  |  $0 connection-limits  |  $0 readonly-role" >&2
  exit 2
}

need_admin() {
  [ -n "$ADMIN_URL" ] || { echo "MAIN_ADMIN_URL missing, run this inside the ops task" >&2; exit 1; }
}

need_source() {
  [ -n "${SOURCE_URL:-}" ] || { echo "set SOURCE_URL to the source database, as the postgres superuser (on Railway its DATABASE_URL)" >&2; exit 1; }
}

need_temporal_password() {
  : "${TEMPORAL_DB_PASSWORD:?TEMPORAL_DB_PASSWORD missing, run this inside the ops task}"
}

admin() { psql "$ADMIN_URL" -X -v ON_ERROR_STOP=1 "$@"; }
src() { psql "$SOURCE_URL" -X -v ON_ERROR_STOP=1 "$@"; }
dst() { psql "$TARGET_URL" -X -v ON_ERROR_STOP=1 "$@"; }

# the admin URL with another database name swapped in
admin_url_for() {
  python3 -c 'import sys; from urllib.parse import urlsplit, urlunsplit; u = urlsplit(sys.argv[1]); print(urlunsplit(u._replace(path="/" + sys.argv[2])))' "$ADMIN_URL" "$1"
}

stop_unless_forced() {
  if [ "${FORCE:-0}" = 1 ]; then
    echo "WARNING (FORCE=1): $*" >&2
  else
    echo "STOP: $*" >&2
    exit 1
  fi
}

# other clients' sessions; autovacuum and other background workers do not count
OTHERS="from pg_stat_activity where datname = current_database() and pid <> pg_backend_pid() and backend_type = 'client backend'"

# exact row count of every table, one query per side
COUNT_SQL="select table_schema || '.' || table_name,
  (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text
  from information_schema.tables
  where table_type = 'BASE TABLE' and table_schema not in ('pg_catalog', 'information_schema')
  order by 1"

# The app roles' caps. temporal's is set with its role (prepare_temporal): the
# main and temporal imports run at the same time, and two sessions altering one
# role at once fail with "tuple concurrently updated".
app_connection_limits() {
  admin -q <<SQL
alter role worker connection limit ${WORKER_CONNECTIONS:-64};
alter role mcp connection limit ${MCP_CONNECTIONS:-100};
SQL
}

connection_limits() {
  app_connection_limits
  if [ -n "$(admin -Atc "select 1 from pg_roles where rolname = 'temporal'")" ]; then
    admin -qc "alter role temporal connection limit ${TEMPORAL_CONNECTIONS:-400}"
  fi
  admin -c "select rolname, rolconnlimit as connection_limit from pg_roles where rolname in ('api', 'mcp', 'worker', 'temporal') order by 1"
}

# The team's read-only login (environments/production/db-readers.tf). They query
# from CloudShell inside the VPC and sign in with an IAM token (rds_iam), so the
# role has no password. It reads every table in public, but the tables below only
# through column grants that leave out the columns holding credentials: OAuth
# tokens and codes, API keys, password hashes, client secrets, webhook URLs (some
# are bearer URLs), Mastra's chat-platform installs and MCP client configs.
# Run it again after a schema change: new tables, and columns Prisma recreates,
# stay unreadable until then. A new column holding a credential goes on this list
# first. The names are Prisma's: the schema has no @map or @@map.
READONLY_ROLE=readonly
READONLY_HIDDEN='{
  "Integration": ["token", "refreshToken", "customInstanceDetails"],
  "Organization": ["apiKey"],
  "User": ["password"],
  "GitHub": ["token"],
  "ThirdParty": ["apiKey"],
  "OAuthApp": ["clientSecret"],
  "OAuthAuthorization": ["accessToken", "authorizationCode"],
  "OAuthSelfHostedAuthorization": ["apiKey", "accessToken", "authorizationCode"],
  "Webhooks": ["url"],
  "mastra_channel_installations": ["data"],
  "mastra_channel_config": ["data"],
  "mastra_mcp_client_versions": ["servers"]
}'

# each hidden column as readonly sees it: hidden, READABLE, or gone from the schema
READONLY_CHECK_SQL="with hidden as (
    select j.key as tbl, c.col
    from jsonb_each('$READONLY_HIDDEN'::jsonb) j
    cross join lateral jsonb_array_elements_text(j.value) as c(col))
  select h.tbl as table_name, h.col as column_name,
    case when cl.oid is null then 'no such table'
         when a.attnum is null then 'no such column'
         when has_column_privilege('$READONLY_ROLE', cl.oid, a.attnum, 'SELECT') then 'READABLE'
         else 'hidden' end as status
  from hidden h
  left join pg_class cl on cl.relname = h.tbl and cl.relnamespace = 'public'::regnamespace
  left join pg_attribute a on a.attrelid = cl.oid and a.attname = h.col and a.attnum > 0 and not a.attisdropped
  order by 1, 2"

READONLY_RELATIONS="from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p', 'v', 'm', 'f')"

readonly_role() {
  local leaks writes create others
  # the role, as the master user (rds_iam can only be granted by it)
  admin -q <<SQL
do \$\$ begin if not exists (select from pg_roles where rolname = '$READONLY_ROLE') then create role $READONLY_ROLE; end if; end \$\$;
-- with rds_iam only IAM tokens sign in; no password, not even an old one
alter role $READONLY_ROLE with login password null connection limit ${READONLY_CONNECTIONS:-5};
grant rds_iam to $READONLY_ROLE;
alter role $READONLY_ROLE set default_transaction_read_only = on;
alter role $READONLY_ROLE set statement_timeout = '${READONLY_STATEMENT_TIMEOUT:-60s}';
alter role $READONLY_ROLE set idle_in_transaction_session_timeout = '1min';
alter role $READONLY_ROLE set lock_timeout = '5s';
grant connect on database "$DB" to $READONLY_ROLE;
grant usage on schema public to $READONLY_ROLE;
-- the table grants run as their owner
do \$\$ begin
  if not pg_has_role(current_user, '$OWNER_ROLE', 'SET') then
    execute format('grant %I to %I with set true', '$OWNER_ROLE', current_user);
  end if;
end \$\$;
SQL

  # SELECT on every table in public, minus the hidden columns; starting from no
  # grants each time, so a column taken off the readable list loses its grant
  dst -q <<SQL
set role "$OWNER_ROLE";
do \$\$
declare
  hidden constant jsonb := '$READONLY_HIDDEN';
  t record;
  cols text;
begin
  for t in
    select c.oid, c.relname, c.relowner = (select oid from pg_roles where rolname = current_user) as owned
    $READONLY_RELATIONS
    order by c.relname
  loop
    if not t.owned then
      raise notice 'skipped %: not owned by %', t.relname, current_user;
      continue;
    end if;
    -- takes back the column grants too
    execute format('revoke all on table public.%I from $READONLY_ROLE', t.relname);
    if hidden ? t.relname then
      select string_agg(quote_ident(a.attname), ', ' order by a.attnum) into cols
      from pg_attribute a
      where a.attrelid = t.oid and a.attnum > 0 and not a.attisdropped
        and not (hidden -> t.relname) ? a.attname;
      if cols is not null then
        execute format('grant select (%s) on table public.%I to $READONLY_ROLE', cols, t.relname);
      end if;
    else
      execute format('grant select on table public.%I to $READONLY_ROLE', t.relname);
    end if;
  end loop;
end
\$\$;
reset role;
SQL

  echo "== hidden columns"
  dst -c "$READONLY_CHECK_SQL"
  leaks=$(dst -Atc "select count(*) from ($READONLY_CHECK_SQL) s where status = 'READABLE'")
  [ "$leaks" = 0 ] || { echo "STOP: $READONLY_ROLE can read $leaks of the credential columns above" >&2; exit 1; }

  echo "== tables in public as $READONLY_ROLE sees them"
  dst -c "select
      count(*) filter (where has_table_privilege('$READONLY_ROLE', c.oid, 'SELECT')) as readable,
      count(*) filter (where not has_table_privilege('$READONLY_ROLE', c.oid, 'SELECT')
                         and has_any_column_privilege('$READONLY_ROLE', c.oid, 'SELECT')) as columns_hidden,
      count(*) filter (where not has_any_column_privilege('$READONLY_ROLE', c.oid, 'SELECT')) as unreadable
    $READONLY_RELATIONS"
  writes=$(dst -Atc "select count(*) $READONLY_RELATIONS
    and (has_table_privilege('$READONLY_ROLE', c.oid, 'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
         or has_any_column_privilege('$READONLY_ROLE', c.oid, 'INSERT, UPDATE, REFERENCES'))")
  [ "$writes" = 0 ] || { echo "STOP: $READONLY_ROLE may change $writes tables in public" >&2; exit 1; }
  create=$(dst -Atc "select has_schema_privilege('$READONLY_ROLE', 'public', 'CREATE') or has_database_privilege('$READONLY_ROLE', current_database(), 'CREATE')")
  [ "$create" = f ] || { echo "STOP: $READONLY_ROLE may create objects in $DB (CREATE granted to PUBLIC?)" >&2; exit 1; }
  others=$(dst -Atc "select string_agg(n.nspname, ', ' order by n.nspname) from pg_namespace n
    where n.nspname not in ('public', 'information_schema') and n.nspname !~ '^pg_'
      and exists (select from pg_class c where c.relnamespace = n.oid and c.relkind in ('r', 'p', 'v', 'm', 'f'))")
  [ -z "$others" ] || echo "not shared with $READONLY_ROLE (only public is): $others"

  admin -c "select rolname, rolconnlimit as connection_limit, rolconfig as settings from pg_roles where rolname = '$READONLY_ROLE'"
  echo "ready: in a CloudShell VPC environment, run the line terraform -chdir=environments/production output -raw db_readonly_psql prints"
}

preflight_source() {
  echo "== source"
  src -c "select current_database() as db, pg_size_pretty(pg_database_size(current_database())) as size, current_setting('server_version') as version"
  src -c "select rolname, rolsuper, rolcreaterole, rolcreatedb, rolcanlogin, rolbypassrls from pg_roles where rolname !~ '^pg_' order by 1"
  src -c "select n.nspname as schema, pg_get_userbyid(c.relowner) as owner, count(*) as objects
          from pg_class c join pg_namespace n on n.oid = c.relnamespace
          where n.nspname not in ('pg_catalog', 'information_schema', 'pg_toast') group by 1, 2 order by 1, 2"
  src -c "select extname, extversion from pg_extension order by 1"
  if [ "$target" = temporal ]; then
    src -c "select db_name, curr_version from schema_version"
    src -c "select count(*) as history_shards from shards"
    src -c "select count(*) as running_workflows from current_executions where status = 1"
  fi

  echo "== safety checks"
  others=$(src -Atc "select count(*) $OTHERS")
  if [ "$others" != 0 ]; then
    src -c "select usename, application_name, client_addr, state $OTHERS"
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
}

preflight_target() {
  echo "== target ($DB)"
  admin -c "select current_setting('server_version') as version"
  if [ -n "$(admin -Atc "select 1 from pg_database where datname = '$DB'")" ]; then
    n=$(dst -Atc "select count(*) from pg_tables where schemaname not in ('pg_catalog', 'information_schema')")
    if [ "$n" != 0 ]; then
      echo "database $DB already has $n tables: restore into an empty database only (migrate-postgres.sh reset)" >&2
      exit 1
    fi
    echo "database $DB exists and is empty"
  else
    echo "database $DB does not exist yet, import creates it"
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
        # no source: the password from <ROLE>_DB_PASSWORD, else from <ROLE>_DATABASE_URL
        # when that URL logs in as this role, so the apps' DATABASE_URLs work as they are
        var="$(echo "$role" | tr '[:lower:]' '[:upper:]')_DB_PASSWORD"
        url_var="$(echo "$role" | tr '[:lower:]' '[:upper:]')_DATABASE_URL"
        hash="${!var:-}"
        if [ -z "$hash" ] && [ -n "${!url_var:-}" ]; then
          hash=$(python3 -c 'import sys; from urllib.parse import urlsplit, unquote; u = urlsplit(sys.argv[1]); print(unquote(u.password or "") if u.username == sys.argv[2] else "")' "${!url_var}" "$role")
        fi
        if [ -z "$hash" ]; then echo "set $var, or $url_var to a URL that logs in as $role" >&2; exit 1; fi
      else
        # same password verifier as on Railway, so the DATABASE_URLs keep working
        hash=$(awk -F '\t' -v role="$role" '$1 == role { print $2 }' "$dir/roles")
        if [ -z "$hash" ]; then echo "role $role missing from $dir/roles" >&2; exit 1; fi
      fi
      hash=${hash//\'/\'\'}
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
  app_connection_limits
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

# source side: everything import needs, into $dir
dump_source() {
  if [ -e "$dir" ] && [ -n "$(ls -A "$dir")" ]; then
    echo "$dir is not empty: export into a new directory" >&2
    exit 1
  fi
  preflight_source
  mkdir -p "$dir"
  src -Atc "select extname from pg_extension where extname <> 'plpgsql' order by 1" > "$dir/extensions"
  if [ "$target" = main ]; then
    # the app roles' password verifiers, not the passwords
    (
      umask 077
      for role in $APP_ROLES; do
        hash=$(src -Atc "select rolpassword from pg_authid where rolname = '$role'")
        if [ -z "$hash" ]; then echo "role $role not found on the source" >&2; exit 1; fi
        printf '%s\t%s\n' "$role" "$hash"
      done > "$dir/roles"
    )
  fi

  echo "== dump ($JOBS jobs)"
  time pg_dump "$SOURCE_URL" --format=directory --jobs="$JOBS" --no-owner --no-privileges --compress=3 --file="$dir/dump"
  du -sh "$dir/dump"

  echo "== row counts"
  if [ "$target" = temporal ]; then
    src -Atc "select count(*) from current_executions where status = 1" > "$dir/running-workflows"
  fi
  # written last and in one step: an export without source-counts is incomplete
  src -AtF $'\t' -c "$COUNT_SQL" > "$dir/source-counts.tmp"
  mv "$dir/source-counts.tmp" "$dir/source-counts"
  echo "exported $(wc -l < "$dir/source-counts") tables to $dir"
}

# AWS side: restore what dump_source wrote into $dir
restore_export() {
  if [ ! -d "$dir/dump" ] || [ ! -f "$dir/source-counts" ]; then
    echo "$dir is not a complete export (migrate-postgres.sh export)" >&2
    exit 1
  fi
  preflight_target
  if [ "$target" = main ]; then prepare_main; else prepare_temporal; fi
  # pg_restore would create them as the restoring role; some need rds_superuser
  for ext in $(cat "$dir/extensions"); do
    dst -qc "create extension if not exists \"$ext\""
    echo "extension $ext"
  done

  echo "== restore as $OWNER_ROLE ($JOBS jobs)"
  # extensions were created above by the admin user; the restoring role may not
  # own them (or the public schema), so their entries and comments are skipped
  pg_restore --list "$dir/dump" | grep -v -E ' EXTENSION - | COMMENT - EXTENSION | COMMENT - SCHEMA public ' > "$dir/restore.toc"
  set +e
  time pg_restore --dbname="$TARGET_URL" --jobs="$JOBS" --no-owner --no-privileges --role="$OWNER_ROLE" \
    --use-list="$dir/restore.toc" "$dir/dump" 2> "$dir/restore.log"
  status=$?
  set -e
  if [ $status -ne 0 ]; then
    echo "pg_restore reported errors (full log: $dir/restore.log):" >&2
    grep -i error "$dir/restore.log" | head -30 >&2
  fi

  if [ "$target" = temporal ]; then
    # Temporal keys its schema version row by database name (Railway: "railway").
    # Without this, auto-setup re-runs every migration and the frontend crash-loops.
    dst -c "update schema_version set db_name = current_database() where db_name <> current_database() returning db_name, curr_version"
    running_src=$(cat "$dir/running-workflows")
    running_dst=$(dst -Atc "select count(*) from current_executions where status = 1")
    if [ "$running_src" = "$running_dst" ]; then
      echo "running workflows: $running_dst, as exported"
    else
      stop_unless_forced "running workflows differ: exported $running_src, restored $running_dst"
    fi
  fi

  echo "== analyze"
  dst -qc "set client_min_messages = error; analyze"

  echo "== verify row counts"
  dst -AtF $'\t' -c "$COUNT_SQL" > "$dir/target-counts"
  if diff "$dir/source-counts" "$dir/target-counts" > "$dir/count-diff"; then
    echo "OK: $(wc -l < "$dir/source-counts") tables, identical row counts"
  else
    echo "ROW COUNT MISMATCH (export < > restored):" >&2
    cat "$dir/count-diff" >&2
    stop_unless_forced "the restored row counts differ from the export"
  fi
  [ $status -eq 0 ] || { echo "pg_restore logged errors, read $dir/restore.log before going on" >&2; exit 1; }
}

copy() {
  preflight_target # the target must be empty before a long dump
  dir="${WORK:-/work}/${target}-$(date +%Y%m%d-%H%M%S)"
  dump_source
  restore_export
}

# new installation without Railway: roles and the temporal database, no data;
# the db-push task then creates the postiz tables and Temporal its schema
init() {
  prepare_main
  prepare_temporal
  echo "ready: set each service's DATABASE_URL to postgresql://<role>:<password>@<host>:5432/postiz?connection_limit=8&application_name=<role>"
}

# Back to empty databases for the test run, or after it, before the real copy.
# The roles and their passwords stay, so the apps' DATABASE_URLs keep working;
# prisma db push recreates the tables, Temporal's auto-setup its schema and index.
reset() {
  local maint others answer
  maint=$(admin_url_for postgres)
  others=$(psql "$maint" -X -Atc "select count(*) from pg_stat_activity where datname in ('$DB', 'temporal') and backend_type = 'client backend'")
  if [ "$others" != 0 ]; then
    psql "$maint" -X -c "select datname, usename, application_name, client_addr from pg_stat_activity where datname in ('$DB', 'temporal') and backend_type = 'client backend'"
    # no FORCE here: a connection means an app, Temporal or a db push still uses these databases
    echo "STOP: $others connections to $DB/temporal. Set apps_enabled = false, push, and wait until every service runs 0 tasks" >&2
    exit 1
  fi
  read -r -p "This deletes all data in $DB, temporal and the $ES_INDEX index on AWS. Type reset to continue: " answer || true
  [ "$answer" = reset ] || { echo "nothing changed" >&2; exit 1; }

  # no FORCE: DROP DATABASE stops autovacuum workers by itself, while FORCE fails for
  # a non-superuser master when one runs ("permission denied to terminate process")
  psql "$maint" -X -v ON_ERROR_STOP=1 -q \
    -c "drop database if exists \"$DB\"" -c "create database \"$DB\"" \
    -c 'drop database if exists temporal'
  # the same grants an import sets up: prisma db push runs as the owner role
  dst -q <<SQL
grant connect, create, temporary on database "$DB" to "$OWNER_ROLE";
grant all on schema public to "$OWNER_ROLE";
SQL
  prepare_temporal
  curl -fsS -X DELETE "$TARGET_ES_URL/$ES_INDEX?ignore_unavailable=true" > /dev/null
  echo "empty: $DB, temporal and $ES_INDEX; logins kept"
}

case "$mode:$target" in
  connection-limits: | temporal-password: | init: | reset: | readonly-role:)
    DB=postiz
    OWNER_ROLE=$(echo "$APP_ROLES" | awk '{print $1}')
    ;;
  preflight:main | export:main | import:main | copy:main)
    DB=postiz
    OWNER_ROLE=$(echo "$APP_ROLES" | awk '{print $1}')
    ;;
  preflight:temporal | export:temporal | import:temporal | copy:temporal)
    DB=temporal
    OWNER_ROLE=temporal
    ;;
  *)
    usage
    ;;
esac

case "$mode" in
  preflight)
    [ -n "${SOURCE_URL:-}$ADMIN_URL" ] || { echo "set SOURCE_URL (source side), or run this inside the ops task (AWS side)" >&2; exit 1; }
    ;;
  export)
    need_source
    [ -n "$dir" ] || usage
    ;;
  import)
    need_admin
    [ -n "$dir" ] || usage
    [ "$target" = main ] || need_temporal_password
    ;;
  copy)
    need_source
    need_admin
    [ "$target" = main ] || need_temporal_password
    ;;
  reset)
    need_admin
    need_temporal_password
    : "${TARGET_ES_URL:?TARGET_ES_URL missing, run this inside the ops task}"
    ES_INDEX=${ES_INDEX:-temporal_visibility_v1_dev}
    ;;
  *)
    need_admin
    case "$mode" in connection-limits | readonly-role) ;; *) need_temporal_password ;; esac
    ;;
esac
if [ -n "$ADMIN_URL" ]; then TARGET_URL=$(admin_url_for "$DB"); fi

case "$mode" in
  preflight)
    if [ -n "${SOURCE_URL:-}" ]; then preflight_source; fi
    if [ -n "$ADMIN_URL" ]; then preflight_target; fi
    ;;
  export) dump_source ;;
  import) restore_export ;;
  copy) copy ;;
  init) init ;;
  reset) reset ;;
  connection-limits) connection_limits ;;
  readonly-role) readonly_role ;;
  temporal-password)
    admin -qc "alter role temporal with login password '$TEMPORAL_DB_PASSWORD'"
    echo "temporal role now uses the current secret; restart the temporal-* services"
    ;;
esac
