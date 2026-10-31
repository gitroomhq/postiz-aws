# postiz-aws

The infrastructure behind [Postiz](https://github.com/gitroomhq/postiz-app)'s
hosted service on AWS, as Terraform, in the open like the app itself. It also
works as a reference for running Postiz on AWS yourself; see
[Running your own](#running-your-own).

It moves the Postiz and Temporal services from Railway to AWS (us-east-2).
Cloudflare R2 (media) and RunPod (media processing) stay where they are.

- Migration steps: [docs/migration-runbook.md](docs/migration-runbook.md)
- License: [AGPL-3.0](LICENSE), like Postiz

## What runs where

```
                     Cloudflare DNS (DNS-only records)
             api / mcp                      platform (the app)
                 |                                 |
                 |                       CloudFront (caches /_next/static)
                 v                                 |
     ALB (public subnets, TLS, host-based rules) <-+
        |                    |
        | instance targets   |
        v                    v
  ECS hosts: 2-4 x r8g.xlarge (Graviton, public subnets, no NAT gateway)
   bridge mode, egress via the host's public IP:
     backend x2 (autoscales to 4) . mcp . frontend x2 . worker . worker-2
   awsvpc mode, private subnets, Cloud Map postiz.internal:
     temporal-frontend x2 . temporal-history x2 . temporal-matching x2 . temporal-worker
     temporal-ui + Caddy basic auth (public, on an unlisted hostname like Railway's)
        |                         |                         |
        v                         v                         v
  RDS PostgreSQL 16          ElastiCache Valkey        Elasticsearch 8.19.10
  db.r8g.large Multi-AZ,     2 x cache.t4g.micro,      1 x r8g.medium + EBS,
  databases postiz and       TLS + AUTH                daily snapshots
  temporal                                             (Temporal visibility)
```

| Railway | AWS |
|---|---|
| Backend Postiz (2), MCP, Frontend, Worker, Worker 2 | ECS services with the same start commands, one image built from postiz-app |
| Postgres + PgBouncer | Database `postiz` on RDS `postiz-production-main`; PgBouncer dropped (see below) |
| Redis | ElastiCache Valkey 8.1 (cluster mode off: Postiz uses a plain ioredis client, which Serverless does not accept) |
| Temporal Frontend/History/Matching/Worker (auto-setup 1.28.0) | Four ECS services, same image and env, IPv4 broadcast address; two tasks each except the system worker |
| Postgres-NlPS | Database `temporal` on the same RDS instance, role `temporal` |
| Elasticsearch (8.19.10) | Same version on one EC2 host with a separate EBS volume |
| Temporal UI + Basic Auth | temporalio/ui 2.39.0 + Caddy basic auth with the same user and password, on a random unlisted hostname like Railway's generated URL |
| Railway variables | Secrets Manager, one JSON secret per service |
| Railway auto-deploy + pre-deploy `prisma db push` | Push to postiz-app main -> `deploy-postiz` workflow: build, db push task, roll services |

### Decisions worth knowing

- **No NAT gateway.** Most of what these services send leaves AWS: uploads
  relayed to R2, social APIs, RunPod. A NAT gateway would add $0.045 to every one
  of those GB, so the internet-facing containers run in bridge mode on hosts with
  public IPs. The hosts' security group only admits the ALB.
- **Workers cannot starve the API of connections.** Each process has a fixed
  pool: Prisma 8 (`connection_limit=8`), plus Mastra's pool in backend and MCP.
  On top of that, Postgres caps every role: `worker` 64, `mcp` 100, `temporal`
  400, `api` uncapped. The caps are set by `migrate-postgres.sh`; re-apply them
  with `migrate-postgres.sh connection-limits` (e.g. `WORKER_CONNECTIONS=128`
  before running more than 8 worker tasks). An alarm fires above 1000 connections
  in total (db.r8g.large allows ~1700). On Railway, PgBouncer's per-user pools did
  this; it ran in session mode, so it never shared connections, and is not needed here.
- **Temporal moves as an exact copy.** Same server build (pinned by digest),
  same schema and shard count, both stores frozen at the same moment, workers
  started only at go-live. The scripts refuse to copy otherwise. See
  [the checklist](docs/migration-runbook.md#temporal-what-keeps-the-workflows-intact).
- **Elasticsearch stays for now.** Postiz finds a post's running workflow with
  `workflow.list('postId="..." AND ExecutionStatus="Running"')` before deleting or
  rescheduling it. Switching an existing cluster to Postgres visibility hides every
  workflow that is already running, and `tdbg workflow refresh-tasks` does not
  rebuild them on 1.28 (tested). A deleted post could still publish. Amazon
  OpenSearch needs Temporal >= 1.30.1, so that is the follow-up after upgrading.
- **No secret in code or state.** Generated passwords (RDS admin, Valkey AUTH,
  Elasticsearch, the `temporal` role) are ephemeral values written write-only into
  the resource and a `postiz/production/managed/*` secret. App secrets are copied
  into Secrets Manager by a script; Terraform only knows their key names.
- **One database instance.** Both databases are light, so they share one
  Multi-AZ db.r8g.large: cheaper than a second instance, and
  Temporal gets Multi-AZ failover. If they ever compete (FreeableMemory,
  ReadIOPS), move `temporal` back out.
- **Temporal survives losing a host.** Frontend, history and matching run two
  tasks each on different hosts. The rehearsal stopped one history task: new and
  existing workflows kept working.
- **Hosts patch themselves.** Each host is replaced every 14 days with the newest
  ECS-optimized AMI (SSM-resolved), and tasks are drained first.

## Cost

Fixed infrastructure at us-east-2 on-demand list prices (October 2026):

| | On-demand / month | With 1-year commitments |
|---|---:|---:|
| ECS hosts: 2 x r8g.xlarge + disks | $360 | $244 |
| Elasticsearch: r8g.medium + 70 GB | $50 | $35 |
| RDS: db.r8g.large Multi-AZ, 100 GB (postiz + temporal) | $372 | $257 |
| Valkey: 2 x cache.t4g.micro | $19 | $13 |
| ALB (hours; plus $0.008 per LCU, about 1 GB/hour processed) | $16+ | $16+ |
| Public IPv4, cross-AZ, Cloud Map (estimate) | $45 | $45 |
| CloudWatch, Secrets Manager, ECR, logs bucket (estimate) | $70 | $70 |

On top of that comes internet egress, $0.09/GB for the first 10 TB a month
(the first 100 GB are free), and usually the largest line for Postiz: media
uploads through the public API stream through the backend to R2. Uploading
straight to R2 with presigned URLs would remove most of it; that is a change in
postiz-app.

Commitments are bought in the console, not in Terraform: an EC2 Instance Savings
Plan for r8g, plus RDS and ElastiCache reserved instances, after a month of real usage.

## Configuration

Nothing account-specific is committed. `terraform.tfvars` holds only public
settings (domains, sizes, image digests, cutover switches); the rest comes from
the environment:

| Where | Name | What |
|---|---|---|
| GitHub secret | `AWS_ACCOUNT_ID` | the only account Terraform may touch; a secret so the public logs print `***` for it |
| GitHub secret | `ALERT_EMAILS` | optional, HCL list: `["ops@example.com"]` |
| GitHub secret | `TEMPORAL_UI_DOMAIN` | the Temporal UI's hostname: a random name under the zone, `temporal-<random>.postiz.com` |
| GitHub secret | `CLOUDFLARE_API_TOKEN` | Zone > Zone > Read and Zone > DNS > Edit, both on the zone only |
| GitHub secret | `APP_REPO_TOKEN` | optional, only if the app repo is private |
| GitHub variable | `TF_STATE_BUCKET` | state bucket, output of `bootstrap/` |
| GitHub variable | `AWS_PLAN_ROLE_ARN`, `AWS_APPLY_ROLE_ARN` | outputs of `bootstrap/` |
| GitHub variable | `AWS_DEPLOY_ROLE_ARN` | output of `environments/production` |
| GitHub variable | `AUTO_DEPLOY` | `true` once AWS serves production |
| GitHub variable | `BUILD_RUNNER`, `APP_REPOSITORY` | optional: arm64 runner label, app repo (default `gitroomhq/postiz-app`) |
| GitHub environment | `production` | terraform apply: main branch only, no reviewers, so every push to main applies (add required reviewers to approve each apply) |
| GitHub environment | `deploy` | deploy-postiz and ops-image: main branch only, no reviewers |
| Local shell | `TF_VAR_aws_account_id`, `TF_VAR_alert_emails`, `TF_VAR_temporal_ui_domain`, `AWS_PROFILE`, `CLOUDFLARE_API_TOKEN` | same values for local runs (an apply without `TF_VAR_alert_emails` removes the alert subscriptions) |
| Local file | `environments/production/backend.hcl` | from `backend.hcl.example` (git-ignored) |

```bash
export TF_VAR_aws_account_id=<account id> AWS_PROFILE=<profile>
terraform -chdir=environments/production init -backend-config=backend.hcl
```

### Running this as a public repository

- Pull requests from forks never get AWS credentials: GitHub gives no OIDC token to fork PRs, and the roles trust only this repository's pull requests and `main` (plan, read-only), the `production` environment (apply) and the `deploy` environment (deploys).
- Turn on *Settings > Actions > Require approval for all outside collaborators*, and restrict both environments to the `main` branch. Every push to `main` applies with the admin role, so write access to this repository means admin on the AWS account: keep it to the people who run production, or add required reviewers to `production`.
- Actions logs of a public repository are public. They contain plans and deploy output (resource IDs, private hostnames), never secret values. The account id is a secret, so the logs print `***` for it, also inside ARNs and the ECR registry name; the alert emails are a secret and a sensitive Terraform variable. PR comments carry only the plan's summary line.
- Automatic deploys only ship commits on the app's `main`: **deploy-postiz** checks a dispatched commit against the app repository before it builds anything, so a leaked dispatch token cannot deploy a branch or a fork's pull request.
- The Temporal UI is public like on Railway, behind basic auth, on an unlisted hostname: a random name kept in the `TEMPORAL_UI_DOMAIN` secret and covered by a wildcard certificate, so it shows up neither in this repository, nor in the logs, nor in certificate transparency logs. `temporal_ui_allowed_cidrs` can limit it to a few IP ranges. Forks can keep the variable's default, `temporal_ui_public = false`: no public hostname at all, `scripts/temporal-ui-tunnel.sh` opens it through Session Manager.

## Layout

```
bootstrap/                 state bucket, GitHub OIDC, plan/apply/read-only roles (applied once, by hand)
modules/
  network/                 VPC, public + private subnets, no NAT
  ecs-cluster/             ECS cluster, Graviton ASG, capacity provider
  ecs-service/             task definition + service (+ ALB, Cloud Map, autoscaling)
  rds-postgres/            RDS with write-only admin password and alarms
environments/production/   everything else; app-env-keys.json = env var names per service
  tests/                   offline plan test with mocked providers
docker/                    postiz.Dockerfile (app), ops.Dockerfile (migration toolbox)
scripts/                   migration, env copy, Temporal UI tunnel, test browser, ECR retag
.github/workflows/         terraform (plan on PR, apply on main), deploy-postiz, ops-image
docs/migration-runbook.md
```

## Day to day

**Infrastructure changes:** open a PR to see the plan first: CI runs fmt,
validate, the offline test and a plan (summary commented on the PR). Every push
to `main` that touches `environments/` or `modules/` applies right away, merges
included, and a local apply that never reaches `main` is undone by the next
push. PR plans run with `-refresh=false`, because the
plan role cannot read any secret value. Do the same when planning with the
read-only profile.

```bash
terraform -chdir=environments/production init -backend=false && terraform -chdir=environments/production test   # offline, no credentials
```

**Deploy Postiz:** pushing to postiz-app `main` deploys it, like on Railway.
postiz-app's `.github/workflows/deploy-aws.yml` sends a `repository_dispatch` to
this repo's **deploy-postiz** workflow. It skips commits that only touch docs,
the extension, the SDK or CI. One-time setup:

1. Create a fine-grained token with *Contents: read and write* on this repository only.
2. Save it in postiz-app as the secret `POSTIZ_AWS_DISPATCH_TOKEN`.
3. Set the variable `AUTO_DEPLOY = true` in this repo at the cutover. Until then dispatches are ignored, because `prisma db push` must not touch the empty database before the restore.

You can also run **deploy-postiz** by hand with any ref. It builds `linux/arm64`
and runs `pnpm run prisma-db-push` as a one-off task (Railway's pre-deploy
command). It only moves `:production` and rolls the five services if that
succeeds. A failed rollout is rolled back by the ECS circuit breaker. Pushes
that land while a deploy runs collapse into one deploy of the newest commit. To
roll back a release, run **deploy-postiz** with the previous commit and
`skip_db_push` checked. The image is reused, and `prisma db push` would refuse to
drop columns the newer release added.

**A new version only takes over once it is healthy.** Deploys are rolling:
ECS starts the new tasks next to the old ones and stops an old task only after
its replacement passes its check:

- **backend, mcp:** load balancer `GET /` (200 "App is running!").
- **frontend:** load balancer `GET /favicon.ico`.
- **worker, worker-2:** the orchestrator's own `/health/status` on port 3002, which answers 200 only once it reaches Temporal.
- **temporal-frontend:** `temporal operator cluster health`.
- **temporal-ui:** Caddy `GET /healthz` as a container check (and through the load balancer when public).

The load balancer sends traffic to a new task after 2 passing checks (15 s
apart), and old tasks get 120 s to finish in-flight uploads. If new tasks keep
failing (3 times for a 1-task service), the circuit breaker rolls the service
back to the previous revision. That includes the previous image digest, even
though `:production` moved. The deploy workflow fails if services are not
stable within 30 minutes.

**Schema changes run once per deploy:** the `db-push` one-off task, started by
**deploy-postiz** and awaited before the rollout. The services only run
`start:prod:*`: unlike the self-hosted image, a container start never touches
the schema. Temporal's own schema check runs when a `temporal-frontend` task
starts, but it changes nothing unless `temporal_image` moved to a newer release.
For that upgrade, set `temporal_task_counts.frontend = 1` for the apply (so one
task migrates), then back to 2.

**Temporal UI:** `terraform -chdir=environments/production output -raw temporal_ui_url`,
behind basic auth with the user and password from `postiz/production/temporal-ui-auth`
(the same as on Railway). With `temporal_ui_public = false` it has no public
hostname, and `scripts/temporal-ui-tunnel.sh` opens it on http://localhost:8081
through Session Manager (needs the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)).

**Change an environment variable:**

1. Edit the value in Secrets Manager (`postiz/production/<service>`).
2. If the key is new, add its name to `environments/production/app-env-keys.json`, or regenerate the file with `scripts/railway-env-to-secrets.py --write-keys` (with `RAILWAY_PROJECT_ID` and `RAILWAY_ENVIRONMENT_ID` set) while Railway is still the source.
3. Apply.
4. Running tasks keep old values until they restart: roll the service with **deploy-postiz**, or run `aws ecs update-service --force-new-deployment`.

**Shell into a container:**

```bash
aws ecs execute-command --cluster postiz-production --task <task-id> --container backend --interactive --command sh
```

**Rotate a generated password:** bump `main_db_password_version` or
`redis_auth_token_version` and apply. The resource and its secret change
together. Then restart the services that read it: backend, mcp, worker and
worker-2 for Valkey; nothing reads the main admin password at runtime.

The `temporal` role is created by the migration script, so Terraform cannot
change its password. Bump `temporal_db_password_version`, apply, run
`migrate-postgres.sh temporal-password` in the ops task, then restart the
`temporal-*` services.

Elasticsearch stores its password in its own data. After bumping
`elasticsearch_password_version`, open a Session Manager shell on the host, run
`rotate-elastic-password`, then restart the `temporal-*` services.

**Read-only access for AI agents:**

```ini
# ~/.aws/config
[profile postiz-readonly]
role_arn = arn:aws:iam::<account id>:role/postiz-agent-readonly
source_profile = <your admin profile>
region = us-east-2
```

It is `ReadOnlyAccess` plus Terraform state, with secret values,
`ecs:ExecuteCommand` and Session Manager denied.

## Running your own

The modules are generic; `environments/production` is Postiz's own setup.

1. Fork, change `github_repository`, `github_oidc_subject` (printed by `gh api repos/<owner>/<name>/actions/oidc/customization/sub --jq .sub_claim_prefix`), the domains, sizes and region in `environments/production/terraform.tfvars`, and set the secrets, variables and environments above (`bootstrap/` takes the same two from `TF_VAR_github_repository` and `TF_VAR_github_oidc_subject`).
2. Follow phase A of the runbook. The Railway-specific steps (copying env vars and data) are optional. For a new installation, fill the Secrets Manager secrets by hand, then in the ops task (runbook B1) run `migrate-postgres.sh init`: it creates the app roles with the passwords of the backend, mcp and worker `DATABASE_URL`s, and the `temporal` database. The first **deploy-postiz** run creates the tables, and Temporal sets up its own schema on start.
3. Your organization may allow different regions; ACM certificates for CloudFront always live in us-east-1.

## Not in this repo yet

The other services Postiz runs on Railway (side apps, automation, the CMS,
monitoring) and a staging environment. `modules/ecs-service` is meant for them:
most are one more `module` block plus a secret.
