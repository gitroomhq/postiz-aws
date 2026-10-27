#!/bin/bash
# Point an ECR tag at the image another tag already has, without pulling it.
#   ecr-retag.sh <repository> <existing tag> <new tag>
# e.g. manual rollback: ecr-retag.sh postiz-app <previous sha> production
set -euo pipefail
repo=$1 from=$2 to=$3

manifest=$(aws ecr batch-get-image --repository-name "$repo" --image-ids imageTag="$from" \
  --query 'images[0].imageManifest' --output text)
media=$(aws ecr batch-get-image --repository-name "$repo" --image-ids imageTag="$from" \
  --query 'images[0].imageManifestMediaType' --output text)
if [ -z "$manifest" ] || [ "$manifest" = None ]; then
  echo "$repo:$from not found" >&2
  exit 1
fi

err=$(mktemp)
if ! aws ecr put-image --repository-name "$repo" --image-tag "$to" \
  --image-manifest "$manifest" --image-manifest-media-type "$media" >/dev/null 2>"$err"; then
  # already pointing there
  grep -q ImageAlreadyExistsException "$err" || { cat "$err" >&2; exit 1; }
fi
rm -f "$err"
echo "$repo:$to -> $repo:$from"
