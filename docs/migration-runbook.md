# Railway -> AWS migration runbook

Moves the **Postiz** group (Backend, MCP, Frontend, Worker, Worker 2, Redis,
Postgres, PgBouncer) and the **Temporal** group (Frontend, History, Matching,
Worker, UI + Basic Auth, Elasticsearch, Postgres-NlPS) from Railway to AWS
us-east-2. R2 and RunPod stay where they are.

Everything else on Railway keeps running untouched, except services that use
the moved databases, see [Before you start](#before-you-start).

Each step below was rehearsed locally with the same images and scripts:

| What | Rehearsed with | Result |
|---|---|---|
| Temporal DB `pg_dump`/`pg_restore` into a database with a new name | temporalio/auto-setup 1.28.0, postgres 16 | needs the `schema_version` rename (the script does it), otherwise auto-setup replays every migration and crash-loops |
| Elasticsearch index copy | ES 8.19.10 -> ES 8.19.10, `scripts/es-copy-index.py` | mapping, template and all docs copied; running workflows still found by `postId`; terminate/new workflows update the copy |
| AWS start command and health check | auto-setup 1.28.0 with `BIND_ON_IP=0.0.0.0` | broadcast address resolved, health check SERVING |
| Main DB roles and ownership | Railway-like source (superuser app roles) -> RDS-like target (non-superuser master) | `api`/`mcp`/`worker` log in with their Railway passwords, `api` owns everything, prisma-style DDL works |
| Temporal DB on the shared instance | `migrate-postgres.sh copy temporal` into an RDS-like instance (TLS on, non-superuser master), Temporal started as role `temporal` | restored objects owned by `temporal`; Temporal runs over TLS with 2 frontends, 2 history, 2 matching, 1 worker |
| Losing a history task | one of the two history tasks stopped | new workflows start and get indexed, existing ones stay readable |
| Postiz image | `docker/postiz.Dockerfile` built from postiz-app main, run with the ECS commands against that Postgres and Temporal | no missing native libraries, `prisma-db-push` in sync (88 tables), backend `GET /` 200, worker polling Temporal, frontend `/favicon.ico` 200 |
| Temporal UI basic auth | caddy 2.10.2 | 401 without credentials, `/healthz` open |

Not rehearsed: anything against the real Railway databases or AWS (that is A6 and Phase B).

---

## Before you start

- **Other services that use the moved databases.** A service outside these two
  groups that connects to the main Postgres (directly or through PgBouncer) or
  to Redis would keep using the old copy after the cutover, because RDS and
  ElastiCache are private. Find them before the window: check the other Railway
  services' variables for references to `Postgres`, `PgBouncer` or `Redis`, and
  read the connection list `migrate-postgres.sh preflight main` prints in A6.
  Stop them in B3 and move them to AWS next, or accept that their writes are lost.
- Tools on your machine: AWS CLI, Terraform >= 1.11,
  the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
  (for `aws ecs execute-command` and host shells), a Cloudflare API token with
  *Zone > Zone > Read* and *Zone > DNS > Edit* on `postiz.com` only.

```bash
export AWS_PROFILE=<profile> AWS_REGION=us-east-2
export TF_VAR_aws_account_id=<account id>
export TF_VAR_alert_emails='["ops@example.com"]'   # same value as the GitHub secret ALERT_EMAILS
export TF_VAR_temporal_ui_domain=<hostname>        # same value as the GitHub secret TEMPORAL_UI_DOMAIN
export CLOUDFLARE_API_TOKEN=...                    # Zone Read + DNS Edit on postiz.com
```

Pick the Temporal UI's hostname once, for example
`echo temporal-$(openssl rand -hex 6).postiz.com`, and keep it out of anything
public: like Railway's generated URL, it stays unlisted.

---

## Temporal: what keeps the workflows intact

Scheduled posts are Temporal workflows sleeping until their publish time. The
move only works if AWS continues exactly where Railway stopped. Each item below
is enforced by the scripts or the configuration, not left to memory:

| Must match | How |
|---|---|
| Server build | `temporal_image` is pinned to the digest Railway runs (`auto-setup:1.28.0`, `sha256:3ee84bf3…`, checked against Docker Hub); the UI likewise (`ui:2.39.0`, `sha256:b768f87f…`) |
| Workflow code replaying the histories | B0b builds the commit Railway runs, and the merge freeze keeps it that way |
| Schema version and shard count | `migrate-postgres.sh` stops unless the source is at schema 1.17 with 4 shards, the values the AWS cluster runs |
| Postgres and Elasticsearch frozen at the same moment | both copies stop if anything is still connected or writing: open connections on the source, or an index that changes during the copy |
| Every row, every running workflow | all table row counts compared, running workflows compared in Postgres and in Elasticsearch |
| Document versions in the index | copied with their external versions, so Temporal's later updates apply (rehearsed: terminate and new workflows after the move) |
| Search attributes `organizationId`, `postId` | come with the database and the index mapping; auto-setup's sample attributes are disabled |
| No double publishing | workers start only at go-live (B12); Railway's Temporal is deleted after it (B15) |

## Phase A: build the platform (no user impact, any day before)

**A1. Bootstrap** (state bucket, GitHub OIDC, CI roles):

```bash
terraform -chdir=bootstrap init
terraform -chdir=bootstrap apply
```

A fork also sets `TF_VAR_github_repository` and `TF_VAR_github_oidc_subject` here
(defaults: this repository) and the same two in
`environments/production/terraform.tfvars`. The subject is what
`gh api repos/<owner>/<name>/actions/oidc/customization/sub --jq .sub_claim_prefix`
prints: repositories created since July 2026 put the owner and repository ids in it.
Then create `environments/production/backend.hcl` from `backend.hcl.example`
with the `state_bucket` output (the file is git-ignored). Optionally move the
bootstrap state into that bucket too: uncomment the `backend "s3"` block in
`bootstrap/main.tf` and run the `init -migrate-state` command written above it.

**A2. GitHub** (repository `gitroomhq/postiz-aws`), see the README's
[Configuration](../README.md#configuration) table:

- Variables: `TF_STATE_BUCKET`, `AWS_PLAN_ROLE_ARN` and `AWS_APPLY_ROLE_ARN`
  (bootstrap outputs).
- Secrets: `AWS_ACCOUNT_ID`, `ALERT_EMAILS`, `TEMPORAL_UI_DOMAIN`, `CLOUDFLARE_API_TOKEN`.
- Environment `production` with *Deployment branches: main only* and no
  reviewers: every push to main that touches `environments/` or `modules/`
  applies. The apply role only trusts jobs running in it.
- Environment `deploy` with *Deployment branches: main only* and no reviewers.
  The deploy role only trusts jobs running in it, so pushes deploy without
  waiting for anyone.
- Leave the variable `AUTO_DEPLOY` unset until B14.
- In postiz-app: commit `.github/workflows/deploy-aws.yml`. Add the secret
  `POSTIZ_AWS_DISPATCH_TOKEN`, a fine-grained token with *Contents: read and
  write* on `gitroomhq/postiz-aws` only. Pushes to main are ignored by
  postiz-aws until `AUTO_DEPLOY` is set.

**A3. First apply**, with every service at 0 tasks (`apps_enabled = false`). The
first push to main that touches `environments/` or `modules/` runs it in the
**terraform** workflow. To run it locally instead, before that push:

```bash
terraform -chdir=environments/production init -backend-config=backend.hcl
terraform -chdir=environments/production apply
```

Takes ~30 minutes (RDS Multi-AZ, CloudFront). Creates the Temporal UI's record
and the ACM validation records in Cloudflare; api/mcp/platform are not touched.
The UI answers once the apps start in B10.
Then set the GitHub variable `AWS_DEPLOY_ROLE_ARN` from the `deploy_role_arn` output,
and check that the hosts registered with Systems Manager (Session Manager shells
need it, for example `rotate-elastic-password` on the Elasticsearch host):
`aws ssm describe-instance-information --query 'InstanceInformationList[].InstanceId'`
lists the ECS hosts and the Elasticsearch host.

**A4. App secrets.** Copies each Railway service's variables into its Secrets
Manager secret, rewriting `DATABASE_URL` to RDS. Both ids are in the Railway
dashboard URL: `railway.com/project/<project id>/...?environmentId=<environment id>`.

```bash
export RAILWAY_PROJECT_ID=<project id> RAILWAY_ENVIRONMENT_ID=<production environment id>
scripts/railway-env-to-secrets.py           # dry run: key names, rewritten hosts, warnings
scripts/railway-env-to-secrets.py --apply
```

Read the warnings. Anything still pointing at `*.railway.internal` must be fixed
by hand.

**A5. Images.**

- Run the **ops-image** workflow (migration toolbox).
- Run **deploy-postiz** with `build_only = true`. This pushes the Postiz image
  and tags it `:production` without `prisma db push`, which must not touch the
  empty database before the restore.

**A6. Rehearse the data copy against live Railway (recommended).** Run B1 and
B6 to B8 with `FORCE=1` while Railway keeps serving (no maintenance page,
nothing stopped), to learn the timings and catch surprises. `FORCE=1` turns the
"writers still connected" and "source changed during the copy" stops into
warnings; never use it in the real window. Do **not** enable the apps. Then empty the targets again, inside the
ops task:

```bash
migrate-postgres.sh reset   # empties postiz, temporal and the Temporal index, keeps the logins; asks you to type reset
```

**A7. Test run on empty databases (recommended).** The whole stack on empty
databases, so Postiz on AWS is used end to end before any real data moves. It
needs the logins A6 created (without A6: `migrate-postgres.sh init` with
`API_DB_PASSWORD`, `MCP_DB_PASSWORD` and `WORKER_DB_PASSWORD` set to the
passwords in the apps' `DATABASE_URL`s).

1. After A6's `reset`, run **deploy-postiz** without `build_only`. This one
   time `prisma db push` is meant to create the tables in the empty database.
2. Set `apps_enabled = true` and `workers_enabled = true`, push, and wait until
   the ECS services run. Temporal's auto-setup creates its schema and the
   `default` namespace; the backend adds Postiz's search attributes when it starts.
3. Open a test window. Only this browser window reaches AWS under the real
   names; everyone else still lands on Railway. Inside AWS, the private zone for
   `api.postiz.com` (dns.tf) sends the frontend's server pages to this backend too.

   ```bash
   open -na "Google Chrome" --args --user-data-dir="$HOME/.postiz-aws-test" \
     --host-resolver-rules="MAP platform.postiz.com <cloudfront_domain>, MAP api.postiz.com <alb_dns_name>, MAP mcp.postiz.com <alb_dns_name>"
   # values: terraform -chdir=environments/production output -raw cloudfront_domain (and alb_dns_name)
   ```

4. Register a test account in that window. With Stripe configured a new
   account gets no channels, so give it a plan (ops task; test database only,
   `reset` deletes it):

   ```bash
   psql "$MAIN_ADMIN_URL" -c "insert into \"Subscription\" (id, \"organizationId\", \"subscriptionTier\", period, \"totalChannels\", \"isLifetime\", \"updatedAt\") select 'test-' || id, id, 'ULTIMATE', 'MONTHLY', 100, true, now() from \"Organization\""
   ```

5. Check in the test window: connect a channel you own, upload an image,
   schedule a post a few minutes ahead and see it published, and open the
   Temporal UI (`terraform output -raw temporal_ui_url`, Railway's login).
   Avoid Telegram (connecting reads the bot's updates, which production reads
   too), VK until its IP allowlist has the AWS address, and the billing pages
   (Stripe is live and its webhooks still go to Railway).
6. Tear down: set `apps_enabled = false` and `workers_enabled = false`, push,
   wait until every service runs 0 tasks, then `migrate-postgres.sh reset` in
   the ops task. Valkey only holds short-lived entries keyed by the test
   account; nothing to clear there.

---

## Phase B: cutover (maintenance window)

Budget the window from the A6 timings; expect roughly 45 to 90 minutes.

Every "set ..., then apply" below is a change to `terraform.tfvars`. Push it to
main and the **terraform** workflow applies it within a few minutes. A local
apply is quicker in the window; push the same change straight after it, because
the next push to main applies what main says and would undo a switch that only
exists on your machine.

| Step | Users see |
|---|---|
| B0 to B1 | nothing yet |
| B2 to B11 | the maintenance page from AWS (API clients and webhooks get a 503 and retry) |
| B12 onwards | Postiz on AWS |

**B0. A few days before:**

- Tell users the date and time: email, in-app notice, social, status page.
- Lower the TTL of the `api`, `mcp` and `platform` records in Cloudflare to 60 seconds.
- Announce a merge freeze on postiz-app `main` for the window.

**B0b. Image = the commit Railway runs:** run **deploy-postiz** with
`build_only = true` and `ref` set to the commit of Railway's current Backend
deployment (normally `main`). Otherwise AWS would start older code than the
database it receives.

**B1. Open the ops toolbox.** It runs as a bridge-mode task, so it reaches both
Railway's public proxies and the private RDS/Elasticsearch endpoints:

```bash
TASK=$(aws ecs run-task --cluster postiz-production --task-definition postiz-production-ops \
  --capacity-provider-strategy capacityProvider=postiz-production-ec2,weight=1 \
  --enable-execute-command --query 'tasks[0].taskArn' --output text)
aws ecs wait tasks-running --cluster postiz-production --tasks "$TASK"
aws ecs execute-command --cluster postiz-production --task "$TASK" --container ops --interactive --command bash
```

Open two or three sessions so the copies run in parallel. Inside,
`MAIN_ADMIN_URL`, `TEMPORAL_DB_PASSWORD` and `TARGET_ES_URL` come from the task
definition. On Railway, make sure each source has a TCP proxy (Settings >
Networking): `Postgres`, `Postgres-NlPS`, and `Elasticsearch` on port 9200. The
`DATABASE_PUBLIC_URL` variables appear once the proxy exists.

**B2. Maintenance page up, DNS to AWS.**

1. In Cloudflare, delete the `api`, `mcp` and `platform` records that point at Railway.
2. Set `maintenance_mode = true` and `dns_cutover = true`, then apply.

Within about a minute users land on AWS and get the maintenance page. Railway
keeps answering whoever still has the old DNS cached until B3.

**B3. Stop the writers on Railway:** scale `Backend Postiz`, `MCP`, `Worker`,
`Worker 2`, `Frontend`, `PgBouncer` and the other services found in
[Before you start](#before-you-start) to 0. PgBouncer goes too: it
holds idle connections, and the copy refuses to start while anything is
connected to the source. Wait two minutes: Temporal indexes
visibility asynchronously (about 50 seconds in the rehearsal).

Record the running workflow count to compare later:

```bash
export SOURCE_ES_URL='http://elastic:<Railway ELASTIC_PASSWORD>@<es proxy host>:<port>'
curl -s -H 'Content-Type: application/json' "$SOURCE_ES_URL/temporal_visibility_v1_dev/_count" \
  -d '{"query":{"term":{"ExecutionStatus":"Running"}}}'
```

**B4. Stop Temporal on Railway:** scale `Temporal Frontend`, `History`,
`Matching` and `Worker` to 0. Leave `Postgres`, `Postgres-NlPS` and `Elasticsearch` running.

**B5. Hard copy on Railway (rollback point):** in Railway, open `Postgres`,
`Postgres-NlPS` and `Elasticsearch` > Backups and create a backup of each volume.
Nothing below writes to Railway, but these survive an accidental delete.

**B6. Main database** (session 1):

```bash
export SOURCE_URL='<Railway Postgres DATABASE_PUBLIC_URL>'
migrate-postgres.sh preflight main     # read the role/owner/extension report
migrate-postgres.sh copy main          # ends with "OK: N tables, identical row counts"
```

**B7. Temporal database** (session 2):

```bash
export SOURCE_URL='<Railway Postgres-NlPS DATABASE_PUBLIC_URL>'
migrate-postgres.sh preflight temporal   # history_shards must be 4; note running_workflows
migrate-postgres.sh copy temporal        # creates role + database temporal, renames the schema_version row
```

**B8. Elasticsearch index** (session 3):

```bash
export SOURCE_ES_URL='http://elastic:<Railway ELASTIC_PASSWORD>@<es proxy host>:<port>'
es-copy-index.py --index temporal_visibility_v1_dev     # ends with "OK: counts match"
```

**B9. Hard copy on AWS** (from your machine; no downtime, Multi-AZ snapshots come from the standby):

```bash
aws rds create-db-snapshot --db-instance-identifier postiz-production-main \
  --db-snapshot-identifier postiz-production-main-cutover
```

**B9b. Re-sync the env vars:** Railway variables may have changed since A4.
Run `scripts/railway-env-to-secrets.py` (same `RAILWAY_*` variables as in A4),
read the dry run, then run it again with `--apply`. Each run writes a new secret version; tasks read the values when they start.

**B10. Start everything except the workers, behind the maintenance page:** set
`apps_enabled = true` and apply, leaving `workers_enabled = false`.

- Temporal, backend, MCP and frontend start.
- Posts that came due during the window wait in Temporal's queue, because nothing
  publishes until the workers run. That keeps a rollback from publishing anything twice.

**B11. Verify through the bypass header:**

```bash
TOKEN=$(terraform -chdir=environments/production output -raw maintenance_bypass_token)
curl -s -o /dev/null -w '%{http_code}\n' -H "X-Postiz-Bypass: $TOKEN" https://api.postiz.com/        # 200
curl -s -o /dev/null -w '%{http_code}\n' https://api.postiz.com/                                   # 503

# from the ops task: same running count as in B3
curl -s -H 'Content-Type: application/json' "$TARGET_ES_URL/temporal_visibility_v1_dev/_count" \
  -d '{"query":{"term":{"ExecutionStatus":"Running"}}}'
```

- In a browser with a header extension (for example ModHeader) sending
  `X-Postiz-Bypass`: log in on platform.postiz.com, open the calendar, open a post.
- The Temporal UI (`terraform -chdir=environments/production output -raw temporal_ui_url`,
  the same basic-auth user and password as on Railway; the maintenance page does
  not cover it) shows the running workflows: the same count as B3, and their
  pending timers.
- ECS console: every service has its tasks running and healthy, with no restart loops.

**Go / no-go:** until B12, rolling back is cheap. The workers never ran on AWS,
so nothing was published from there, and Railway's frozen state is still the
truth:

1. Set `dns_cutover = false` and `maintenance_mode = false`, then apply.
2. Re-create the Railway CNAMEs in Cloudflare.
3. Scale the Railway services back up.

After B12, going back means copying data the other way.

**B12. Go live:** set `workers_enabled = true` and `maintenance_mode = false` in the
same apply.

- The traffic switch is seconds.
- The workers take a minute or two to pass their health check.
- Then the posts that came due during the window go out.

**B13. Smoke test:**

1. Log in.
2. Schedule a post (Temporal start).
3. Delete a post that was scheduled **before** the migration (visibility lookup by `postId`).
4. Upload media through the public API.
5. Open a post preview.

**B14. Switch deploys over:**

- Set the postiz-aws variable `AUTO_DEPLOY = true`, so pushes to postiz-app main deploy to AWS.
- In Railway, disconnect the GitHub repo from the five Postiz services, so a push no longer redeploys them there.

**B15. Afterwards:**

- Delete the four Railway Temporal services (Frontend, History, Matching, Worker)
  right after go-live; keep `Postgres-NlPS` and `Elasticsearch` with their backups.
  If Railway's Temporal and workers ever ran again, they would replay the frozen
  state and publish those posts a second time.
- Keep the other stopped Railway services and the databases for one to two weeks,
  then delete them. Their backups can stay longer.
- Keep the `cutover` RDS snapshot for 30 days.
- Raise the Cloudflare TTLs again.

---

## After the migration

- **Deploys:** the **deploy-postiz** workflow (manual, or a `repository_dispatch`
  from postiz-app on every push to main).
- **Moving visibility off Elasticsearch** needs Temporal >= 1.30.1 (Amazon
  OpenSearch support). Upgrade one minor version at a time (1.28 -> 1.29 -> 1.30),
  then plan the visibility move. Do not switch the existing cluster to Postgres
  visibility: the rehearsal showed running workflows disappear from
  `workflow.list`, and nothing rebuilds them on 1.28.
