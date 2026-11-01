#!/bin/bash
# Decides which app images a deploy builds, which services it restarts and whether
# it runs prisma db push: Railway's per-service watch paths, with each app compared
# against the commit it runs now (the commit tag on its <app>-production image).
# Used by .github/workflows/deploy.yml; images come from docker/postiz-app.Dockerfile.
#
#   frontend       apps/frontend/**       -> service frontend
#   backend        apps/backend/**        -> services backend, mcp
#   orchestrator   apps/orchestrator/**   -> services worker, worker-2
#   every app      libraries/**, root build files, anything not listed as neutral
#   no app         docs, .github, apps/extension|sdk|commands, local dev files
#   prisma db push schema.prisma changed since the schema the database has: the
#                  commit on migrate-production, which only a successful push moves
#
# An app is built and restarted when something that touches it changed since its
# live commit, or when that is unclear: no live image yet, its commit is not an
# ancestor (rollback, rewritten history), or GitHub cannot list the diff (300+
# files). A re-run of the live commit restarts the app onto the existing image.
# libraries/** means every app: the workers import react-shared-libraries, and
# helpers is used everywhere. Manual runs build and restart everything.
#
# Environment: SHA, EVENT (github.event_name), APP_REPOSITORY, APP_TOKEN,
# REPOSITORY (ECR). Local checks: LIVE_FRONTEND / LIVE_BACKEND /
# LIVE_ORCHESTRATOR / LIVE_MIGRATE=<sha or empty> skip ECR, CHANGED_FILES (one
# path per line, used for every comparison) skips GitHub.
# Output: apps (JSON list), services (space-separated), db_push (true|false),
# to $GITHUB_OUTPUT when set, plus a summary for the run page.
set -euo pipefail
: "${SHA:?}"
APPS="frontend backend orchestrator"

services_of() {
  case $1 in
    frontend) echo frontend ;;
    backend) echo backend mcp ;;
    orchestrator) echo worker worker-2 ;;
  esac
}

# the commit an image tag runs: the <prefix><sha> tag next to it
live() { # tag prefix
  local var
  var="LIVE_$(echo "$1" | sed 's/-production$//' | tr 'a-z-' 'A-Z_')"
  if [ -n "${!var+x}" ]; then echo "${!var}"; return; fi
  aws ecr describe-images --repository-name "$REPOSITORY" --image-ids imageTag="$1" \
    --query 'imageDetails[0].imageTags' --output text 2>/dev/null \
    | tr '\t' '\n' | sed -n "s/^$2\([0-9a-f]\{40\}\)\$/\1/p" | head -1 || true
}

# files changed from a base commit to SHA; fails when that is unclear
changed() { # base
  if [ -n "${CHANGED_FILES+x}" ]; then printf '%s\n' "$CHANGED_FILES"; return 0; fi
  local cmp status
  cmp=$(curl -fsSL -H "Authorization: Bearer $APP_TOKEN" -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/$APP_REPOSITORY/compare/$1...$SHA") || return 1
  status=$(jq -r .status <<< "$cmp")
  case $status in ahead | identical) ;; *) return 1 ;; esac
  [ "$(jq '.files | length' <<< "$cmp")" -lt 300 ] || return 1
  jq -r '.files[] | .filename, (.previous_filename // empty)' <<< "$cmp"
}

touches() { # file -> the app it touches, "all", or nothing
  case $1 in
    apps/frontend/*) echo frontend ;;
    apps/backend/*) echo backend ;;
    apps/orchestrator/*) echo orchestrator ;;
    *.md | .github/* | apps/extension/* | apps/sdk/* | apps/commands/* | Jenkins/* | reports/* | .claude/* | .devcontainer/* \
      | docker-compose*.yaml | Dockerfile.dev | railway.toml | .coderabbit.yaml | sonar-project.properties | .env.example) ;;
    *) echo all ;;
  esac
}

apps="" services="" db_push=false why=""
note() { why="$why"$'\n'"- $1"; }

if [ -z "${CHANGED_FILES+x}" ] && [ "${EVENT:-}" != repository_dispatch ]; then
  apps="$APPS" db_push=true
  note "manual run: every app"
else
  : "${APP_REPOSITORY:=}" "${APP_TOKEN:=}" "${REPOSITORY:=}"
  for app in $APPS; do
    base=$(live "$app-production" "$app-")
    if [ -z "$base" ]; then apps="$apps $app"; note "$app: no live image yet"; continue; fi
    if [ "$base" = "$SHA" ]; then apps="$apps $app"; note "$app: already on ${SHA:0:12}, restarting it"; continue; fi
    if ! files=$(changed "$base"); then apps="$apps $app"; note "$app: cannot compare ${base:0:12}...${SHA:0:12}"; continue; fi
    hit=""
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      t=$(touches "$f")
      if [ "$t" = all ] || [ "$t" = "$app" ]; then hit=$f; break; fi
    done <<< "$files"
    if [ -n "$hit" ]; then apps="$apps $app"; note "$app: changed since ${base:0:12} ($hit)"
    else note "$app: unchanged since ${base:0:12}"; fi
  done
  base=$(live migrate-production migrate-)
  if [ -z "$base" ]; then db_push=true; note "db push: no schema pushed by this pipeline yet"
  elif [ "$base" = "$SHA" ]; then note "db push: schema of ${SHA:0:12} already pushed"
  elif ! files=$(changed "$base"); then db_push=true; note "db push: cannot compare ${base:0:12}...${SHA:0:12}"
  elif grep -qxE 'libraries/nestjs-libraries/src/database/prisma/schema\.prisma' <<< "$files"; then
    db_push=true; note "db push: schema.prisma changed since ${base:0:12}"
  else note "db push: schema unchanged since ${base:0:12}"; fi
fi

for app in $apps; do services="$services $(services_of "$app")"; done
apps=$(echo $apps)
services=$(echo $services)
build=$apps
if [ "$db_push" = true ]; then build="$build migrate"; fi
json=$(printf '%s\n' $build | jq -Rsc 'split("\n") | map(select(length > 0))')

echo "apps=$json"
echo "services=$services"
echo "db_push=$db_push"
echo "why:${why}"
if [ -n "${GITHUB_OUTPUT:-}" ]; then printf 'apps=%s\nservices=%s\ndb_push=%s\n' "$json" "$services" "$db_push" >> "$GITHUB_OUTPUT"; fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  printf '### Deploy plan for %s\n- builds: `%s`\n- restarts: `%s`\n- prisma db push: %s\n%s\n' \
    "${SHA:0:12}" "${json}" "${services:-nothing}" "$db_push" "$why" >> "$GITHUB_STEP_SUMMARY"
fi
