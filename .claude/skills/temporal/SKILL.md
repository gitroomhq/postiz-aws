---
name: temporal
description: Query production Temporal, where every scheduled Postiz post is a workflow, through scripts/temporal-cli.sh (a Session Manager tunnel, no open port). Use for a post that didn't publish or published twice, stuck or failing workflows, workflow history, task-queue backlog or workers, and Temporal health. Read commands only; any change to Temporal needs the user's OK first.
argument-hint: "[question, post ID or workflow ID]"
allowed-tools:
  - Bash(scripts/temporal-cli.sh workflow *)
  - Bash(scripts/temporal-cli.sh task-queue *)
  - Bash(scripts/temporal-cli.sh schedule *)
  - Bash(scripts/temporal-cli.sh batch *)
  - Bash(scripts/temporal-cli.sh worker *)
  - Bash(scripts/temporal-cli.sh operator *)
---

# Production Temporal

## Running commands

Run `scripts/temporal-cli.sh <temporal command>` from the repository root with Bash.
It opens a Session Manager tunnel through an ECS host to
temporal-frontend.postiz.internal:7233, runs that one command and closes the
tunnel (about 5 s). Put the command first, then its flags. Several calls can run
at once. Add `-o json` when you need to parse the output. The app namespace is
`default`, which is also the CLI's default.

- This uses the local AWS CLI, not the AWS MCP server: the MCP sandbox can't
  hold a Session Manager connection.
- Don't use the keep-open form (the script with no arguments). Stopping it as a
  background task leaves the SSM session connected; if that happens, end it with
  ssm TerminateSession.
- Always give `workflow list` a `--limit`: every scheduled post is a running
  workflow, far too many to list.
- `workflow result` and `workflow trace` wait until the workflow ends, which for
  a scheduled post can be days away.

## Changes need the user's OK

The frontend has no authorization: anyone connected can terminate, reset or
delete anything. The script runs only reads (list, describe, show, count, query
and similar) and refuses anything else unless `--write` comes first. Before any
`--write` command, show the user the exact command and what it will change, and
wait for their OK. Don't get around the check with the keep-open tunnel or a raw
`temporal` call. The `allowed-tools` grant above leaves `--write` out on
purpose, so it still goes through the normal permission check.

Be most careful with `post_*` workflows: terminating one means that post never
publishes, and resetting one can publish it twice.

## When it fails

- AccessDenied on ssm:StartSession, ExpiredToken, or no credentials: the shell
  needs an admin sign-in (both read-only roles deny Session Manager). Ask the
  user to sign in again in a real terminal (`aws login --profile <profile>`);
  don't try other roles.
- `SessionManagerPlugin is not found`: install the Session Manager plugin.
  `temporal: command not found`: `brew install temporal`.
- `the tunnel did not open within 30 s`: check that the ECS hosts are online in
  Systems Manager (ssm DescribeInstanceInformation).

## Postiz in Temporal

From the orchestrator source (gitroomhq/postiz-app, apps/orchestrator), checked
against production on 2026-11-03.

| Workflow type | Workflow ID | What it is |
|---|---|---|
| `postWorkflowV112` | `post_<postId>` | One per scheduled post: sleeps until the publish date, then publishes through the provider's activity queue. Repeat posts start `post_<postId>_<random>` children. Posts scheduled long ago can still run an older version (V101 to V111). |
| `missingPostWorkflow` | `missing-post-workflow` | Hourly sweep: starts or pokes `post_<id>` for top-level posts still in QUEUE whose publish date passed within the last 2 days. The backend starts it at boot when RUN_CRON is set. |
| `refreshTokenWorkflow` | `refresh_<integrationId>` | Keeps a channel's token fresh. |
| `streakWorkflowV2` | `streak_<organizationId>` | Posting streak per organization. |
| `digestEmailWorkflow` | `digest_email_workflow_<organizationId>` | Digest of notification emails (signal-with-start). |
| `sendSingleEmailWorkflow`, `sendEmailWorkflow` | `send_email_<uuid>` | One email. |
| `autoPostWorkflow` | `autopost-<autopostId>` | Auto-post from a feed. |
| `processMediaWorkflow` | `media_<mediaId>` | Media processing. |
| `clippingWorkflow`, `clippingClipWorkflow` | `clipping_<id>`, `clipping_clip_<clipId>` | Video clipping. |
| `generateVideoWorkflow` | the job ID | Video generation. |

- Task queues: every workflow runs on `main`. Activities run on `main`, on one
  queue per provider (the provider identifier before any `-`, lowercased: `x`,
  `linkedin`, `reddit` and so on) and on `email` and `email-bulk` (rate
  limited). The pollers are the worker and worker-2 services.
- Search attributes: `postId` and `organizationId` (Text). Post workflows started
  by the app carry both; repeat-post children carry only `postId`.
- A post's database state goes from QUEUE to PUBLISHED or ERROR. The workflow
  stores reasons such as `No Post`, `Already posted`, `Refresh channel needed`
  and `Channel disabled`.

## Recipes

A post that didn't publish:

```bash
scripts/temporal-cli.sh workflow list --query 'postId="<postId>"' --limit 20   # every run, repeat-post children too
scripts/temporal-cli.sh workflow describe -w post_<postId>                       # status, pending activities, attempts, last failure
scripts/temporal-cli.sh workflow show -w post_<postId> -o json                   # full history: the timer, each activity, failures
```

No workflow at all while the post is still in QUEUE: it was never started or was
terminated, and only the hourly sweep would start it, if it is at most 2 days
overdue. Check that the sweep runs: `workflow describe -w missing-post-workflow`.

Anything else:

```bash
scripts/temporal-cli.sh operator cluster health                    # SERVING
scripts/temporal-cli.sh task-queue describe --task-queue main      # pollers and backlog; also per provider, e.g. --task-queue x
scripts/temporal-cli.sh workflow count --query 'ExecutionStatus="Running" AND WorkflowType="postWorkflowV112"'
scripts/temporal-cli.sh workflow list --query 'ExecutionStatus="Failed" AND CloseTime > "2026-11-01T00:00:00Z"' --limit 20
scripts/temporal-cli.sh workflow list --query 'organizationId="<orgId>" AND ExecutionStatus="Running"' --limit 20
```
