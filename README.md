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
     temporal-readonly: Caddy passing only read calls (the CLI tunnel's reads)
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
| Resend (email) | Amazon SES in us-east-2 as postiz.com, sent with each service's task role ([ses.tf](environments/production/ses.tf)); `ses_sending_enabled` switches backend, mcp and the workers over |
| (new) games.postiz.com | Static files of the postiz-games repository in a private S3 bucket behind CloudFront ([games.tf](environments/production/games.tf)), deployed by the `deploy-games` workflow |
| Railway auto-deploy + pre-deploy `prisma db push` | `deploy-postiz` workflow, started by hand with a code from an authenticator: build, db push task, roll services |

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
- **A web firewall that only counts.** AWS WAF sits on the load balancer with
  Amazon's IP reputation list, the known-bad-inputs and core rule sets and two
  rate limits, all in count mode: they record what they would block and let it
  through. The generic core rules would stop real traffic here (bodies over 8 KB,
  requests without a User-Agent, OAuth redirects to 127.0.0.1, long activation
  links), so those keep counting for good
  ([waf.tf](environments/production/waf.tf)). A rule blocks only once it is named
  in `waf_blocking_rules`. On an ALB, WAF reads the first 8 KB of a body, no more.

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
| AWS WAF: web ACL and 5 rules (plus $0.60 per million requests) | $10+ | $10+ |
| Security alerts: GuardDuty (hosts, Fargate tasks, databases, API calls; plus $1 per GB of DNS logs), audit trail copy, alarms (estimate) | $50+ | $50+ |
| games.postiz.com: S3 + CloudFront (within CloudFront's free 1 TB / 10M requests a month) | ~$1 | ~$1 |

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
| GitHub secret | `GAMES_REPO_TOKEN` | optional, only if the games repo is private (contents: read) |
| GitHub variable | `TF_STATE_BUCKET` | state bucket, output of `bootstrap/` |
| GitHub variable | `AWS_PLAN_ROLE_ARN` | output of `bootstrap/` |
| GitHub variable | `DEPLOY_GATE_URL` | output `deploy_gate_url` of `bootstrap/`: where the workflows ask the [deploy gate](#deploy-gate) for credentials |
| GitHub variable | `BUILD_RUNNER`, `APP_REPOSITORY` | optional: arm64 runner label, app repo (default `gitroomhq/postiz-app`) |
| GitHub variable | `GAMES_REPOSITORY` | optional: games repo (default `gitroomhq/postiz-games`) |
| GitHub environment | `production` | terraform apply: main branch only. The deploy gate gives the admin role only to jobs in it |
| GitHub environment | `deploy` | deploy-postiz and ops-image: main branch only. The deploy gate gives the deploy role only to jobs in it |
| Local shell | `TF_VAR_aws_account_id`, `TF_VAR_alert_emails`, `TF_VAR_temporal_ui_domain`, `AWS_PROFILE`, `CLOUDFLARE_API_TOKEN` | same values for local runs (an apply without `TF_VAR_alert_emails` removes the alert subscriptions) |
| Local file | `environments/production/backend.hcl` | from `backend.hcl.example` (git-ignored) |

```bash
export TF_VAR_aws_account_id=<account id> AWS_PROFILE=<profile>
terraform -chdir=environments/production init -backend-config=backend.hcl
```

### Running this as a public repository

- Pull requests from forks never get AWS credentials: GitHub gives no OIDC token to fork PRs, and the only role that trusts GitHub is the read-only plan role, for this repository's pull requests and `main`.
- Write access to this repository is not access to production. The roles that change anything are handed out by the [deploy gate](#deploy-gate), only to a run of a commit someone approved from their own machine, started with a code from an authenticator. What write access does give is the plan role: any branch can change the workflow a pull request runs, so whoever can push can read what `ReadOnlyAccess` reads and the Terraform state (no secret values). Keep write access to the people who run production.
- Turn on *Settings > Actions > Require approval for all outside collaborators*, and restrict both environments to the `main` branch.
- Actions logs of a public repository are public. They contain plans and deploy output (resource IDs, private hostnames), never secret values. The account id is a secret, so the logs print `***` for it, also inside ARNs and the ECR registry name; the alert emails are a secret and a sensitive Terraform variable. PR comments carry only the plan's summary line.
- Deploys only ship commits on the app's `main`: **deploy-postiz** checks the commit against the app repository before it builds anything, so a deploy cannot be pointed at a branch or at a fork's pull request, which anyone can open.
- The Temporal UI is public like on Railway, behind basic auth, on an unlisted hostname: a random name kept in the `TEMPORAL_UI_DOMAIN` secret and covered by a wildcard certificate, so it shows up neither in this repository, nor in the logs, nor in certificate transparency logs. `temporal_ui_allowed_cidrs` can limit it to a few IP ranges. Forks can keep the variable's default, `temporal_ui_public = false`: no public hostname at all, `scripts/temporal-ui-tunnel.sh` opens it through Session Manager.

## Deploy gate

Nothing in GitHub can change production on its own. The two roles that can, the
admin role of `terraform apply` and the deploy role, do not trust GitHub. They
trust one Lambda function, the deploy gate (`bootstrap/deploy-gate.tf`), and it
gives a workflow run one hour of credentials only when all of these hold:

- **A code.** The run was started by hand with a 6-digit code from an
  authenticator app (the workflow's `otp` input). A code works once, for about a
  minute.
- **Of the person who started the run.** Everyone who may deploy has their own
  authenticator, tied to their GitHub account: a code only opens runs its owner
  started, and five wrong ones lock out that person and nobody else.
- **A trusted commit.** The run is on `main` of this repository, at the commit
  you last approved from your own machine with `scripts/deploy-gate.sh trust`.

So a stolen GitHub account or token gets no credentials, and neither does a
stolen phone without its owner's GitHub account. A changed workflow, script or
Terraform file is a new commit, which the gate refuses until someone with admin
credentials for the account has trusted it; the trusted workflows do nothing
without a code; and deleting the check from a workflow removes nothing, because
the check is in AWS. `bootstrap/` is applied by hand and never by CI, so a pull
request cannot change the gate either.

| When | What you do |
|---|---|
| Every deploy, every `terraform apply`, every ops image build | Run the workflow by hand and type the code. Each run needs a new one |
| After every new commit on this repository's `main` | `scripts/deploy-gate.sh trust`: it lists the commits and files changed since the trusted commit and asks before it moves. Read the change first: this is the review the gate relies on |
| A run was refused | The job log says why: a wrong, used or expired code, a commit that is not trusted, or a re-run (a re-run is a new attempt with the old code, so start a new run). A run that waits behind another deploy starts with an expired code: start it when the other one is done |
| Someone is locked out | `scripts/deploy-gate.sh reset <github user>`, after looking at where the wrong codes came from: `aws logs tail /aws/lambda/postiz-deploy-gate --since 1d`. If it was not them, someone has their GitHub account: `revoke` instead |
| Did anyone try to get past it | `aws logs tail /aws/lambda/postiz-deploy-gate --since 7d --filter-pattern refused`: every refusal with the repository, branch, commit, run and person GitHub's token names. A refused run at a commit you do not know is someone changing the workflows |
| Someone new should deploy | `scripts/deploy-gate.sh enroll <github user>`, in your own terminal, see below |
| New phone, lost phone | `scripts/deploy-gate.sh enroll <github user> --rotate`: the old entry stops working |
| Someone leaves, or their GitHub account or phone may be in other hands | `scripts/deploy-gate.sh revoke <github user>`: from the next request on, also for a run of theirs that is under way |
| What is trusted, who may start runs, what is approved | `scripts/deploy-gate.sh status` |

`scripts/deploy-gate.sh` needs admin credentials for the account
(`export AWS_PROFILE=<profile>`), which is the point: trusting a commit,
unlocking and enrolling cannot be done from GitHub.

**Who may deploy.** Someone who deploys needs two things: write access to this
repository, to start a workflow, and an authenticator from `enroll`. They need
no AWS access. Write access alone changes nothing in production, and what they
push here runs only after `trust`.

```
scripts/deploy-gate.sh enroll <github user>           # may deploy and build the ops image
scripts/deploy-gate.sh enroll <github user> --apply   # may also run terraform apply
scripts/deploy-gate.sh grant <github user> deploy|apply   # change that later, same authenticator
```

`enroll` shows that person's secret once, as a QR code when `qrencode` is
installed, and stores it only after a code from their phone proves they have
it. Let them scan your screen, or give them the setup key over a channel you
trust; whoever sees it can make their codes, though only that person's GitHub
account can spend them. The gate knows people by GitHub's numeric user id, so
renaming an account changes nothing and a freed name gives the next owner
nothing. A code deploys what postiz-app's `main` holds and applies what this
repository's trusted commit holds, nothing else, whoever types it.

**More than one repository.** The gate can serve other repositories of the same
owner: `deploy_gate_repositories` in `bootstrap/variables.tf` names them, and
`bootstrap/local.auto.tfvars` is read by Terraform and ignored by git, for names
that should not be public. Each one has its own trusted commit: `cd` into a
clone of it and run this repository's `scripts/deploy-gate.sh trust` from
there. Its jobs call a copy of `scripts/gate-ci.sh`, the GitHub environment of
a job says which role it gets, and those roles trust the gate's role and
nothing else, like the two here. People and authenticators are the same
everywhere: whoever may deploy here may deploy there, and a code is spent once
for all of them.

What the gate does not do:

- It does not read the change for you. `trust` approves a commit of this
  repository, and a code deploys whatever postiz-app's `main` holds.
- It does not cover the read-only plan role, which pull requests use.
- It does not stand between the account's admins and the account.

**How it works.** A job asks GitHub for a token that says which repository,
branch, commit, run, attempt and environment it is, and sends it to the gate's
address (`scripts/gate-ci.sh`). API Gateway verifies GitHub's signature on the
token and the function decides on what it says (`bootstrap/deploy-gate/handler.py`):
the first job of a run sends the code and gets that run attempt approved, for 90
minutes in the `deploy` environment and two hours in `production`; every later
job gets credentials for the role of its environment while the approval lasts.
The token also names who started the run, and the code is checked against that
person's secret. The function logs every decision, refusals included, with the
run that asked, never a code or a credential. A secret is created by `enroll`
on your machine and stored where only the function can read it, one Secrets
Manager secret per person; none is in a Terraform state.

**Setting it up** (once, in this order, so that nothing is locked out):

1. `terraform -chdir=bootstrap init && terraform -chdir=bootstrap apply` creates
   the gate. From this moment GitHub can no longer assume the apply role.
2. `scripts/deploy-gate.sh enroll <your github user> --apply`, in your own
   terminal: it shows the secret once, as a QR code when `qrencode` is
   installed, and checks a code from your phone before it stores anything.
3. Set the repository variable `DEPLOY_GATE_URL` to
   `terraform -chdir=bootstrap output -raw deploy_gate_url`.
4. With the workflows of this version on `main`: `scripts/deploy-gate.sh trust`.
5. Run the **terraform** workflow with a code. It applies
   `environments/production`, which takes the deploy role away from GitHub too.
   Until this apply, deploys fail: the gate cannot hand out a role that does not
   trust it yet.

If the gate itself is broken, admin credentials still work: apply locally
(`terraform -chdir=environments/production apply`), and fix the gate with
`terraform -chdir=bootstrap apply`.

## Layout

```
bootstrap/                 state bucket, GitHub OIDC, plan/apply/read-only roles, the deploy gate (applied by hand, never by CI)
modules/
  network/                 VPC, public + private subnets, no NAT
  ecs-cluster/             ECS cluster, Graviton ASG, capacity provider
  ecs-service/             task definition + service (+ ALB, Cloud Map, autoscaling)
  rds-postgres/            RDS with write-only admin password and alarms
  guardduty/               GuardDuty in one Region, findings sent on to the Region with the alerts
environments/production/   everything else; app-env-keys.json = env var names per service
  tests/                   offline plan test with mocked providers
docker/                    postiz-app.Dockerfile (one image per app), postiz.Dockerfile (all-in-one, before the split), ops.Dockerfile (migration toolbox)
scripts/                   migration, env copy, Temporal UI tunnel and CLI, read-only psql, test browser, ECR retag, deploy gate (deploy-gate.sh for you, gate-ci.sh for the workflows)
.claude/skills/temporal/   Claude Code skill: production Temporal through scripts/temporal-cli.sh
.github/workflows/         terraform (plan on PR, apply by hand), deploy-postiz, deploy-games, ops-image: all change production only through the deploy gate
docs/migration-runbook.md
```

## Day to day

**Games (games.postiz.com):** Actions > **deploy-games** > Run workflow with a
code and a commit of postiz-games' `main` (default `main`). It uploads the files
(HTML revalidates on every visit, the rest is cached an hour in browsers) and
clears the CloudFront cache; a rollback is the same run with an older commit.
To add a game, change only the postiz-games repository.

**Infrastructure changes:** open a PR to see the plan first: CI runs fmt,
validate, the offline test and a plan (summary commented on the PR). Nothing
applies on a merge. To apply what `main` holds: `scripts/deploy-gate.sh trust`
(once per new commit on `main`, it shows what changed), then Actions >
**terraform** > Run workflow with a code from the authenticator, see
[Deploy gate](#deploy-gate). A local apply that never reaches `main` is undone
by the next apply. PR plans run with `-refresh=false`, because the
plan role cannot read any secret value. Do the same when planning with the
read-only profile.

```bash
terraform -chdir=environments/production init -backend=false && terraform -chdir=environments/production test   # offline, no credentials
```

**Channel token encryption:** the tokens Postiz holds for the connected
channels can be stored encrypted ([encryption.tf](environments/production/encryption.tf)):
postiz-app encrypts them with a data key that only KMS can give back, so a copy
of the database or of the secrets cannot read them. `token_encryption` in
`terraform.tfvars` turns it on in three applies:

1. `off` (default): creates the KMS key, an empty secret and the task roles'
   `kms:Decrypt`. Then run `scripts/token-encryption-key.sh` once to create the data key.
2. `read-only`: backend, mcp and the workers get the key and read encrypted
   tokens, new ones are still stored plain. Needs a postiz-app that has the encryption.
3. `on`, once every service runs with step 2: new and refreshed tokens are
   stored encrypted. Older tokens keep working plain; start postiz-app's
   `encryptTokensWorkflow` (task queue `main`) to encrypt them all:
   `scripts/temporal-cli.sh --write workflow start --type encryptTokensWorkflow --task-queue main --workflow-id encrypt-tokens`

The KMS key and the data key secret must never be deleted (every channel would
have to be connected again), and after step 3 a postiz-app from before the
encryption must never be deployed. To step back, use `read-only`, not `off`.

**Deploy Postiz:** Actions > **deploy-postiz** > Run workflow: type the code from
the authenticator and, to deploy something other than the head of postiz-app's
`main`, an earlier commit of it. Nothing deploys on a push, and every deploy
needs its own code, see [Deploy gate](#deploy-gate). A run that changes nothing
an app is built from (docs, the extension, the SDK, CI) builds and restarts
nothing. The run's summary links the commit that is deploying, its author and
its pull request.

**One slim image per app, built only when the app changed**
(`docker/postiz-app.Dockerfile`; postiz-app's own all-in-one image stays the
self-hosting path and is not changed):

| Image | Services | Contents |
|---|---|---|
| `frontend-<sha>` | frontend | Next standalone server (switched on by a config wrapper at build time) |
| `backend-<sha>` | backend, mcp | the backend build and only the files `main.js` loads (traced with `@vercel/nft`) |
| `orchestrator-<sha>` | worker, worker-2 | the same for the workers, plus every file Temporal's workflow bundler reads at startup |
| `migrate-<sha>` | db push task | Prisma CLI and `schema.prisma` |

The **deploy-postiz** run has three jobs. **plan** (`scripts/deploy-plan.sh`)
compares each app with the commit it runs now, the `<app>-<sha>` tag next to its
`<app>-production` tag: `apps/frontend` touches the frontend, `apps/backend` the
backend (and mcp), `apps/orchestrator` the workers, and `libraries/**` or the root
build files every app. **build** builds only those images, in parallel, one job
each, and reuses an image already pushed for the commit. **release** runs
`prisma db push` when `schema.prisma` changed since the schema the database has
(the commit on `migrate-production`, which only a successful push moves), moves
`<app>-production` and restarts only those
services. Anything unclear (no live image, a rollback, rewritten history, a huge
diff) builds and restarts that app, and a run with `all` checked does all of
them. The run's summary shows the plan and why.

A deploy builds `linux/arm64`
and runs the db push as a one-off task (Railway's pre-deploy command), and only
moves the release tags and rolls the services if that succeeds. A failed rollout
is rolled back by the ECS circuit breaker; after a failed db push the next deploy
pushes again. Deploys run one at a time. To roll back a release, run
**deploy-postiz** with the previous commit and `skip_db_push` checked. Its images
are reused when they exist, and `prisma db push` would refuse to drop columns the
newer release added.

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
though `<app>-production` moved. The deploy workflow fails if services are not
stable within 30 minutes.

**Schema changes run once per deploy:** the `db-push` one-off task, started by
**deploy-postiz** and awaited before the rollout. The services only start their
app (`node .../main.js`, `node server.js`, the image's own command): unlike the
self-hosted image, a container start never touches the schema. Temporal's own schema check runs when a `temporal-frontend` task
starts, but it changes nothing unless `temporal_image` moved to a newer release.
For that upgrade, set `temporal_task_counts.frontend = 1` for the apply (so one
task migrates), then back to 2.

**Temporal UI:** `terraform -chdir=environments/production output -raw temporal_ui_url`,
behind basic auth with the user and password from `postiz/production/temporal-ui-auth`
(the same as on Railway). With `temporal_ui_public = false` it has no public
hostname, and `scripts/temporal-ui-tunnel.sh` opens it on http://localhost:8081
through Session Manager (needs the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)).

**Temporal CLI:** `scripts/temporal-cli.sh workflow list --limit 5` opens a
Session Manager tunnel through an ECS host, runs one `temporal` command and
closes the tunnel (about 5 s). No port opens on AWS. With no arguments it keeps
the tunnel open on `localhost:17233` (`export TEMPORAL_ADDRESS=localhost:17233`),
never 7233, so a local Postiz or dev server can't reach production.

The frontend has no authorization, so reads go to the read-only proxy
`temporal-readonly.postiz.internal:7233` instead
([temporal-readonly.tf](environments/production/temporal-readonly.tf)): Caddy
passes an exact list of read calls (list, describe, get, count, query, health)
and answers anything else with 403 (Forbidden), whatever client connects. Its
access log records every call, refused ones included. The tunnel uses the
Session Manager document `postiz-team-temporal-readonly`
([team-tunnels.tf](environments/production/team-tunnels.tf)), which fixes the
host and port, so the team's read-only role (postiz-team-readonly) can use it
too: bootstrap/ denies that role every session document not named
`postiz-team-*`, the shell included.
`--write` tunnels straight to the frontend for any command and needs an admin
sign-in. The script also refuses non-read commands before connecting unless
`--write` comes first. Needs the Session Manager plugin and the Temporal CLI
(`brew install temporal`); postiz-agent-readonly denies Session Manager.
Claude Code uses it through the project skill `.claude/skills/temporal`
(`/temporal`), which also maps Postiz's workflows: types, IDs, task queues and
what to check when a post didn't publish.

**Google sign-in in front of the public Temporal UI:** the load balancer sends
everyone to Google's sign-in first, and only signed-in requests reach the UI (and
its basic auth). Nothing in the app changes. To turn it on:
1. In Google Cloud Console, in a project of the postiz.com Workspace: set up the
   OAuth consent screen (Google Auth Platform) with the audience **Internal**, so
   only Workspace accounts can sign in. The load balancer itself never checks
   which account signed in.
2. Create an OAuth client of type **Web application** with the authorized redirect
   URI `https://<temporal_ui_domain>/oauth2/idpresponse`.
3. Store its ID and secret as the repository secrets `TEMPORAL_UI_GOOGLE_CLIENT_ID`
   and `TEMPORAL_UI_GOOGLE_CLIENT_SECRET`, then run the **terraform** workflow.
   It adds the sign-in step to the UI's listener rule, and lets the load balancer
   reach Google's token endpoint over HTTPS. A session lasts 12 hours, and signing
   in again is a redirect without a prompt while the Google session lasts.
Removing both secrets and running the workflow again turns it off.

**Web firewall (AWS WAF):** every rule counts until it is named in
`waf_blocking_rules`. What a rule matched is in CloudWatch (namespace
`AWS/WAFV2`, `CountedRequests` per rule) and in the log group
`aws-waf-logs-postiz-production`, which keeps only counted and blocked requests,
with the `authorization`, `cookie` and `auth` headers removed. To make a rule
block, add its name to `waf_blocking_rules` in `terraform.tfvars` and apply;
take it out to go back to counting. `waf_enabled = false` detaches the web ACL.
While the list is empty, the alarm `postiz-production-waf-blocked` fires if
anything is blocked at all.

**Security alerts:** `security.tf` and `audit-trail.tf` tell when someone got
in; they block nothing. Everything arrives from the sender **Postiz SECURITY**
(the topic `postiz-production-security`, the same addresses as the alarms), so
a mail filter can send it to a phone. An address receives nothing until it
opened the confirmation link AWS mailed it after the apply.

| Alert | It means | Usual innocent cause |
|---|---|---|
| GuardDuty finding, severity 4 and up | AWS saw a known attack pattern: a stolen credential used from a new place, a crypto miner or reverse shell on a host, an odd sign-in or an unusual volume of reads on a database | none; read the finding |
| `shell-session` | ECS Exec, or a Session Manager shell on a host | you, debugging |
| `database-change` | an RDS instance, snapshot or parameter group was changed, shared, copied, exported or restored, outside the deploy gate | a change by hand |
| `network-opened` | a security group got a new inbound rule, outside the deploy gate | a change by hand |
| `detection-changed` | the trail, GuardDuty, an alert rule, an alarm or the topic was changed, outside the deploy gate | a change by hand |
| alarm `...-security-iam-user-or-key` | an IAM user, password or access key was created | none: the account has no IAM users |
| alarm `...-security-iam-role-change` | a role or its permissions changed, outside the deploy gate | a `bootstrap/` apply, which is always by hand |
| alarm `...-security-other-region` | something was created or changed outside us-east-2 | none |
| alarm `...-security-root-used` | the root user acted | none |
| Cost anomaly | a service costs $100 more than its history predicts | a real traffic jump |

"Outside the deploy gate" means: not by the roles the gate hands out
(`gated_apply_role_names`), so a `terraform apply` run from Actions with a code
is quiet. The team's tunnels and port forwards are quiet too
(`quiet_session_documents`), or the dozens a day would bury the rest.

When one arrives and it was not you or the team: the email names the role and
the address the call came from. Every API call of the last 90 days is
searchable in Logs Insights on `/aws/cloudtrail/postiz-production` (older ones,
up to 400 days, are files in the `postiz-production-cloudtrail-*` bucket), and
who connected to PostgreSQL in `/aws/rds/instance/postiz-production-main/postgresql`.
A credential that may be in other hands: `scripts/deploy-gate.sh revoke` for a
person's deploy access, and for an app's secret, change it at its source and in
Secrets Manager, then restart the services.

What it does not see: a break-in through Postiz itself (a stolen admin login,
an API used within its limits), and what was typed in a shell. GuardDuty's
agent runs on the EC2 hosts, and as a sidecar container in the Fargate tasks of
the internal apps, where a service gets it with its next deployment
(`guardduty_runtime_monitoring = false` takes it off everywhere,
`guardduty_fargate_monitoring = false` off the Fargate tasks). The first 30 days of
GuardDuty are free, and its console's Usage page shows what each part will
cost. This repository is public, so anyone can read which calls alert.

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

**Query the database (read-only):** members of the team's read-only group in
IAM Identity Center (the account access manager entitlement to
`postiz-team-readonly`) can run SQL on the `postiz` database from their own
machine through a Session Manager tunnel, or from CloudShell inside the VPC. The
database has no public endpoint, and the tunnel (document
`postiz-team-postgres-readonly`,
[team-tunnels.tf](environments/production/team-tunnels.tf)) reaches only its
PostgreSQL port. Either way they sign in as the PostgreSQL role `readonly` with a
15-minute IAM token, so the role has no password and the tunnel alone signs
nobody in. It reads every table except the columns
that hold credentials (OAuth tokens and codes, API keys, password hashes, OAuth
client secrets, webhook URLs, Mastra's chat-platform and MCP configs). On those
few tables `SELECT *` fails, so name the columns. Transactions are read-only,
statements stop after 60 seconds, and the role gets 5 connections. The team
role also can't download the RDS log files, which hold slow statements with
their parameters.

From your own machine, signed in with `aws login` (the read-only access or an
admin one), with the Session Manager plugin and psql (`brew install libpq`):

```bash
scripts/psql-readonly.sh                                    # interactive psql
scripts/psql-readonly.sh -c 'select count(*) from "Post"'   # one query, any psql arguments
scripts/psql-readonly.sh --tunnel                           # localhost:15432 for another client
```

From CloudShell:

1. Sign in through the access portal with the read-only access, switch to
   us-east-2 and open **CloudShell**.
2. **Actions > Create VPC environment**: VPC `postiz-production`, one of its
   private subnets, security group `postiz-production-db-readers`. Any other
   choice is refused.
3. Connect, with the endpoint from the RDS console (`postiz-production-main` >
   Connectivity & security). `terraform output -raw db_readonly_psql` prints
   this line filled in.

   ```bash
   H=<endpoint>
   PGPASSWORD="$(aws rds generate-db-auth-token --region us-east-2 --hostname $H --port 5432 --username readonly)" \
     psql "host=$H port=5432 dbname=postiz user=readonly sslmode=require"
   ```

The environment reaches the database but not the internet, and CloudShell
deletes it after 20 to 30 idle minutes; create it again the same way. The
columns a restricted table shows:
`select column_name from information_schema.column_privileges where grantee = 'readonly' and table_name = 'Integration';`

Setup and upkeep: `migrate-postgres.sh readonly-role` in the ops task (runbook
B1) creates the role and its grants. Run it again after a schema change: new
tables, and columns Prisma recreates, stay unreadable until then. A new column
that holds a credential goes on the script's `READONLY_HIDDEN` list first. IAM
sign-in is on in Terraform, but on an existing instance it waits for the
maintenance window; `aws rds modify-db-instance --db-instance-identifier postiz-production-main --enable-iam-database-authentication --apply-immediately`
turns it on now, without downtime. To give someone access, create their
Identity Center user and add them to the read-only group.

## Running your own

The modules are generic; `environments/production` is Postiz's own setup.

1. Fork, change `github_repository`, the domains, sizes and region in `environments/production/terraform.tfvars`, and set the secrets, variables and environments above. `bootstrap/` takes your repository from `TF_VAR_github_repository`, `TF_VAR_github_oidc_subject` (printed by `gh api repos/<owner>/<name>/actions/oidc/customization/sub --jq .sub_claim_prefix`), and for the deploy gate `TF_VAR_github_repository_id` and `TF_VAR_github_repository_owner_id` (`gh api repos/<owner>/<name> --jq '.id, .owner.id'`).
2. Follow phase A of the runbook. The Railway-specific steps (copying env vars and data) are optional. For a new installation, fill the Secrets Manager secrets by hand, then in the ops task (runbook B1) run `migrate-postgres.sh init`: it creates the app roles with the passwords of the backend, mcp and worker `DATABASE_URL`s, and the `temporal` database. The first **deploy-postiz** run creates the tables, and Temporal sets up its own schema on start.
3. Your organization may allow different regions; ACM certificates for CloudFront always live in us-east-1.

## Not in this repo yet

The other services Postiz runs on Railway (side apps, automation, the CMS,
monitoring) and a staging environment. `modules/ecs-service` is meant for them:
most are one more `module` block plus a secret.
