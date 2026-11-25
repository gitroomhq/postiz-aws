#!/bin/bash
# Opens staging's Temporal UI on http://localhost:8080: Session Manager forwards
# the port into the Temporal task (environments/staging/temporal.tf), where the
# UI runs next to the server. Nothing about it is public.
# Needs the staging account's credentials (AWS_PROFILE) and the Session Manager plugin.
# Always local port 8080: the UI's TEMPORAL_CORS_ORIGINS is http://localhost:8080.
set -euo pipefail
CLUSTER=${CLUSTER:-postiz-staging}
export AWS_REGION=${AWS_REGION:-us-east-2}

task=$(aws ecs list-tasks --cluster "$CLUSTER" --service-name temporal --desired-status RUNNING \
  --query 'taskArns[0]' --output text)
if [ "$task" = None ] || [ -z "$task" ]; then
  echo "the temporal service has no running task" >&2
  exit 1
fi
runtime=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$task" \
  --query "tasks[0].containers[?name=='temporal'].runtimeId | [0]" --output text)

echo "Temporal UI on http://localhost:8080 (Ctrl-C closes the tunnel)"
exec aws ssm start-session --target "ecs:${CLUSTER}_${task##*/}_${runtime}" \
  --document-name AWS-StartPortForwardingSession \
  --parameters "portNumber=8080,localPortNumber=8080"
