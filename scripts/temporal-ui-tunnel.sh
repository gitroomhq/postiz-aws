#!/bin/bash
# Opens the Temporal UI on http://localhost:8081 when it has no public hostname
# (temporal_ui_public = false): Session Manager forwards the port from one of the
# ECS hosts to the UI task.
# Needs the AWS CLI with access to the account and the Session Manager plugin.
# The UI still asks for the basic-auth user/password (postiz/production/temporal-ui-auth).
# Always local port 8081: the UI's TEMPORAL_CORS_ORIGINS is http://localhost:8081.
set -euo pipefail
CLUSTER=${CLUSTER:-postiz-production}

task=$(aws ecs list-tasks --cluster "$CLUSTER" --service-name temporal-ui --desired-status RUNNING \
  --query 'taskArns[0]' --output text)
if [ "$task" = None ] || [ -z "$task" ]; then
  echo "the temporal-ui service has no running task" >&2
  exit 1
fi
ip=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$task" \
  --query "tasks[0].attachments[0].details[?name=='privateIPv4Address'].value | [0]" --output text)
container_instance=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$task" \
  --query 'tasks[0].containerInstanceArn' --output text)
instance=$(aws ecs describe-container-instances --cluster "$CLUSTER" --container-instances "$container_instance" \
  --query 'containerInstances[0].ec2InstanceId' --output text)

echo "Temporal UI on http://localhost:8081 (Ctrl-C closes the tunnel)"
exec aws ssm start-session --target "$instance" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "host=$ip,portNumber=8081,localPortNumber=8081"
