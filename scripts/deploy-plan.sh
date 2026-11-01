#!/bin/bash
# Decides which services an automatic deploy restarts and whether it runs prisma
# db push, from the files changed since the commit :production runs now: the
# AWS version of Railway's per-service watch paths. Used by .github/workflows/deploy.yml.
#
#   frontend                    always (Railway rebuilt it on every push)
#   backend, mcp                apps/backend/**
#   worker, worker-2            apps/orchestrator/**
#   all of them                 libraries/**, root build files, anything not listed below
#   no service                  docs, .github, apps/extension|sdk|commands, local dev files
#   prisma db push              schema.prisma, package.json or pnpm-lock.yaml changed
#
# Anything unclear rolls every service and runs db push: a manual run (rollbacks),
# no commit tag on :production, a re-run of the live commit, a commit that is not
# ahead of the live one, or a diff GitHub truncates. A needless restart is cheap,
# a missed one is not. libraries/** always means everything: the workers import
# react-shared-libraries, and helpers is used by every app.
#
# Environment: SHA (commit to deploy), EVENT (github.event_name), APP_REPOSITORY,
# APP_TOKEN, REPOSITORY (ECR). For local checks: BASE skips the ECR lookup,
# CHANGED_FILES (one path per line) skips GitHub.
# Output: services=... and db_push=true|false, to $GITHUB_OUTPUT when set.
set -euo pipefail
: "${SHA:?}"
ALL="backend mcp frontend worker worker-2"

result() { # services db_push reason
  echo "services=$1"
  echo "db_push=$2"
  echo "why: $3"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then printf 'services=%s\ndb_push=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; fi
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '### Deploy plan\n- restarts: `%s`\n- prisma db push: %s\n- why: %s\n' "$1" "$2" "$3" >> "$GITHUB_STEP_SUMMARY"
  fi
  exit 0
}

if [ -n "${CHANGED_FILES+x}" ]; then
  files=$CHANGED_FILES
  base=${BASE:-local}
else
  [ "${EVENT:-}" = repository_dispatch ] || result "$ALL" true "manual run: every service"
  : "${APP_REPOSITORY:?}" "${APP_TOKEN:?}" "${REPOSITORY:?}"
  base=${BASE:-$(aws ecr describe-images --repository-name "$REPOSITORY" --image-ids imageTag=production \
    --query 'imageDetails[0].imageTags' --output text 2>/dev/null | tr '\t' '\n' | grep -E '^[0-9a-f]{40}$' | head -1 || true)}
  [ -n "$base" ] || result "$ALL" true "no commit tag on :production"
  [ "$base" != "$SHA" ] || result "$ALL" true "$SHA is already :production (re-run)"
  cmp=$(curl -fsSL -H "Authorization: Bearer $APP_TOKEN" -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/$APP_REPOSITORY/compare/$base...$SHA") \
    || result "$ALL" true "could not compare ${base:0:12}...${SHA:0:12}"
  status=$(jq -r .status <<< "$cmp")
  [ "$status" = ahead ] || result "$ALL" true "${SHA:0:12} is '$status' of the live ${base:0:12} (rollback or rewritten history)"
  # GitHub lists at most 300 files per comparison
  [ "$(jq '.files | length' <<< "$cmp")" -lt 300 ] || result "$ALL" true "300 or more files changed"
  files=$(jq -r '.files[] | .filename, (.previous_filename // empty)' <<< "$cmp")
fi

backend=false workers=false all=false db_push=false
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in
    libraries/nestjs-libraries/src/database/prisma/schema.prisma | package.json | pnpm-lock.yaml) db_push=true ;;
  esac
  case "$f" in
    apps/frontend/*) ;;
    apps/backend/*) backend=true ;;
    apps/orchestrator/*) workers=true ;;
    *.md | .github/* | apps/extension/* | apps/sdk/* | apps/commands/* | Jenkins/* | reports/* | .claude/* | .devcontainer/* \
      | docker-compose*.yaml | Dockerfile.dev | railway.toml | .coderabbit.yaml | sonar-project.properties | .env.example) ;;
    *) all=true ;;
  esac
done <<< "$files"

count=$(grep -c . <<< "$files" || true)
range="${base:0:12}...${SHA:0:12}, $count files"
if [ "$all" = true ]; then result "$ALL" "$db_push" "shared code or build files changed ($range)"; fi
services="frontend"
if [ "$backend" = true ]; then services="backend mcp $services"; fi
if [ "$workers" = true ]; then services="$services worker worker-2"; fi
result "$services" "$db_push" "no shared code changed ($range)"
