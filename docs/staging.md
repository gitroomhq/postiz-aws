# Staging

A small copy of production for testing features from any branch of postiz-app
and for pentests. It runs in its own AWS account, on Fargate Spot, at
platform.getpostiz.com, and only people holding a client certificate get in.

## What it is

| | Production | Staging |
|---|---|---|
| Account | the workload account | its own member account, boxed in by `bootstrap/staging/account-policy.json` |
| Domain | platform/api/mcp.postiz.com | platform/api/mcp.getpostiz.com: its own login cookie (`.getpostiz.com`), never sent to production |
| Who gets in | everyone | port 443 asks for a client certificate of the staging CA before anything reaches the app |
| Compute | EC2 hosts | Fargate Spot, one task each: backend (also serves mcp), frontend, worker (all queues), Temporal (all four roles + UI) |
| Temporal visibility | Elasticsearch | Postgres (`temporal_visibility`); postiz-app registers its search attributes itself |
| Database | db.r8g.large Multi-AZ | db.t4g.micro, one AZ |
| Valkey | 2 nodes | 1 node, same TLS + AUTH |
| Frontend | through CloudFront | straight to the load balancer (CloudFront cannot present a client certificate) |
| Email | SES, production access | SES in the sandbox: verified recipients only, so staging never mails a real user |
| Token encryption | own KMS key | its own KMS key, in the staging account |
| Deploys | main only, authenticator code | any branch of postiz-app, no code (`deploy-staging.yml`) |
| Data | customers | empty, never a copy of production (it holds customers' channel tokens) |

About $105 a month (us-east-2 prices, November 2026): Fargate Spot ~$20,
database $14, Valkey $9, load balancer ~$18, client-certificate check $3.65,
six public IPv4 addresses $22, GuardDuty ~$7, the rest (secrets, KMS, logs, DNS,
images) ~$9. A budget alert fires at $150 (`monthly_budget_usd`).

## Who gets in

Client certificates (`scripts/staging-certs.py`). The load balancer's port 443
runs mutual TLS in verify mode: a connection without a certificate signed by the
staging CA is closed during the handshake, so the internet cannot even see the
app. The connection log (`s3://postiz-staging-alb-logs-<account>/connections/`)
names the certificate of every connection.

    export AWS_PROFILE=postiz-staging STAGING_ACCOUNT_ID=<staging account id>
    scripts/staging-certs.py issue dana                 # dana.p12 + a password, printed once
    scripts/staging-certs.py issue pentester-1 --days 21  # a pentester, for the engagement
    scripts/staging-certs.py issue sam --csr sam.csr    # sign their request: their key stays with them
    scripts/staging-certs.py list
    scripts/staging-certs.py revoke pentester-1           # in force within a minute or two

Send the .p12 and its password by different channels. Install: double-click it
(macOS Keychain, Windows); Chrome and Safari then offer it when a staging page
asks. Burp: Settings > Network > TLS > Client TLS certificates, host
`*.getpostiz.com`. curl: `openssl pkcs12 -in dana.p12 -nodes > me.pem`, then
`curl --cert me.pem https://api.getpostiz.com/`.

Use a Chromium browser (Chrome, Edge, Brave, Burp's built-in one). The app at
platform.getpostiz.com calls api.getpostiz.com, another origin, so the browser
first sends a CORS preflight. The Fetch spec sends no client certificate with
it, and Firefox follows the spec: there every API call fails unless
`network.cors_preflight.allow_client_cert` is set to true in about:config.
Chromium sends the certificate anyway, though its maintainers call that a bug.
Testing tools other than browsers (Burp's proxy, curl) send no preflight.

A certificate is a file: someone who copies it from a laptop can use it until it
expires or is revoked. Revoke at once when a laptop is lost, and keep the days
short for people outside the team.

Without certificates (a pentest whose tools cannot present one): set
`client_certificates_required = false` and `open_to_cidrs` to their fixed
addresses, apply, and switch back afterwards. Plain 0.0.0.0/0 is refused.

The one door without a certificate is Stripe's: port 8443 accepts only Stripe's
webhook addresses and forwards only `POST /stripe` on api.getpostiz.com; the app
still checks Stripe's signature. Stripe's docs do not say whether a webhook URL
may use a port other than 443: if the test-mode endpoint
`https://api.getpostiz.com:8443/stripe` is refused, the fallback is a small API
Gateway route on 443 (not built yet).

## Setting it up

Once, in this order. Steps marked (mgmt) need the management account
(`aws login --profile postiz-mgmt`, in a real terminal).

1. **Account** (mgmt). Create it with a root email no AWS account uses yet:

       aws organizations create-account --account-name "Postiz Staging" --email <root email>
       aws organizations describe-create-account-status --create-account-request-id <id>

2. **Organization policy** (mgmt). One Region (us-east-2), no EC2 machines, no
   IAM users or access keys, GuardDuty and CloudTrail cannot be switched off
   except by the admin and Terraform roles, no root user:

       aws organizations create-policy --type SERVICE_CONTROL_POLICY --name postiz-staging-account \
         --description "Postiz staging: one Region, no machines, no users, detection stays on" \
         --content file://bootstrap/staging/account-policy.json
       aws organizations attach-policy --policy-id <policy id> --target-id <staging account id>

3. **Admin access** (mgmt), as for the other accounts (account access manager,
   not permission sets): from the management account assume
   `OrganizationAccountAccessRole` in the new account, create `AccountFullAccessRole`
   (path `/`, trusted by `account-access.amazonaws.com`, AdministratorAccess), and
   add a group `<staging account id>-AdministratorAccess` with an entitlement to it.
   Then a CLI profile `postiz-staging`: `aws login --profile postiz-staging --region us-east-2`.

4. **Bootstrap** (state bucket, GitHub OIDC, plan and apply roles):

       export AWS_PROFILE=postiz-staging TF_VAR_aws_account_id=<staging account id>
       terraform -chdir=bootstrap/staging init && terraform -chdir=bootstrap/staging apply

5. **GitHub** (repository settings of postiz-aws):
   - environments `staging` and `staging-terraform`, each with deployment
     branches limited to `main`
   - variables `STAGING_TF_STATE_BUCKET`, `STAGING_AWS_PLAN_ROLE_ARN`,
     `STAGING_AWS_APPLY_ROLE_ARN` (bootstrap outputs), later `STAGING_DEPLOY_ROLE_ARN`
   - secrets `STAGING_AWS_ACCOUNT_ID`, `STAGING_CLOUDFLARE_API_TOKEN` (getpostiz.com
     only: Zone > Zone > Read, Zone > DNS > Edit), optionally `STAGING_SES_RECIPIENTS`
     (an HCL list of the testers' addresses)

   The local gh is too old for `gh variable`: `gh api -X POST repos/gitroomhq/postiz-aws/actions/variables -f name=... -f value=...`.

6. **Cloudflare**: delete the old `platform` and `api` records of getpostiz.com
   (proxied CNAMEs to a Railway app that no longer exists). Terraform creates
   new ones and a name can only have one CNAME.

7. **Client CA**: `scripts/staging-certs.py init`, then commit
   `environments/staging/client-ca.pem` (public by nature; the key stays in
   Secrets Manager under `postiz/staging-admin/`, which no task can read).

8. **First apply**, with `apps_enabled = false` (terraform.tfvars): Actions >
   terraform-staging > Run workflow on main. Put the `deploy_role_arn` output
   into `STAGING_DEPLOY_ROLE_ARN`.

9. **Token encryption key**, once:

       AWS_PROFILE=postiz-staging NAME=postiz-staging SECRET=postiz/staging/token-encryption-data-key scripts/token-encryption-key.sh

10. **Secrets**: `scripts/staging-secrets.py fill` writes every key with staging's
    URLs, a new `JWT_SECRET`, the settings `shared-keys.json` copies from
    production, and "" for the rest. Then fill in the console what staging needs:
    Stripe test-mode keys, a staging R2 bucket and its keys
    (`CLOUDFLARE_*`), staging API keys with spending caps (OpenAI, FAL, ...),
    the providers' test apps. `scripts/staging-secrets.py missing` lists what is
    still empty. The frontend's `NEXT_PUBLIC_*` values are compiled into its image,
    so set them before the first build.

11. **Images**: deploy-staging with `build_only` (branch `main`).

12. **Apps on**: `apps_enabled = true` in a pull request, merge, apply.

13. **First deploy**: deploy-staging with `init_database` (creates the roles
    api, worker, mcp and temporal, and Temporal's two databases; then prisma
    db push). The Temporal task starts once its databases exist; give it a few
    minutes.

14. **Certificates** for everyone (above), and the Stripe test-mode webhook
    `https://api.getpostiz.com:8443/stripe` with its signing secret in
    `STRIPE_SIGNING_KEY`.

## Day to day

- Deploy a branch: Actions > deploy-staging > Run workflow (on main) with the
  postiz-app branch name. Moving to a branch with a different schema may need
  `accept_data_loss`; staging's data is disposable.
- Temporal UI: `AWS_PROFILE=postiz-staging scripts/staging-temporal-ui.sh`, then http://localhost:8080.
- A shell in a container: `aws ecs execute-command --cluster postiz-staging --task <id> --container backend --interactive --command sh`
  (it sends a security alert, on purpose).
- Rotate the database or Valkey passwords: bump the `*_version` variable, apply,
  deploy with `init_database` (database), and the services pick them up.

## Shared production keys

Some providers allow one app only, so staging may use production's OAuth app
for them. List each such key under `shared` in
`environments/staging/shared-keys.json` and run `staging-secrets.py fill`. Whoever
breaks into staging can read those keys, so keep the list short. The script
refuses the keys that would hand staging control of production (`NEVER_COPY` in
the script): `JWT_SECRET`, Stripe, R2, the Farcaster mnemonic, bot tokens,
billing and webhook secrets, analytics. Connect only test social accounts, and
never flood or fuzz the posting paths of a shared provider: the provider sees
production's app doing it.

## Pentests

- **Access**: one certificate per tester, `--days` = the engagement. If their
  tools cannot present one, `open_to_cidrs` with their fixed addresses instead.
- **Scope to agree in writing**: platform, api and mcp on getpostiz.com only.
  Not production (postiz.com), not the social networks' APIs.
- **AWS's rules** (https://aws.amazon.com/security/penetration-testing/): testing
  ECS, Fargate, the load balancer, RDS and CloudFront needs no approval; denial
  of service and request flooding are prohibited (their own DDoS simulation
  process); command-and-control (C2) needs AWS's approval first.
- **Data**: create test users in two organizations, so they can test whether
  one tenant reaches another's data. The app's source is public, so they can
  also test with the code at hand.
- **Shared keys**: empty `shared` for the engagement, or plan to rotate them in
  production afterwards: if they get code running in a task, they see every
  secret it has.
- **Alerts**: GuardDuty and the audit trail will fire. Keep the emails and
  compare them with the report: it shows what a real attack would have set off.
- **Afterwards**: revoke their certificates, put `client_certificates_required`
  back if it was off, and rotate whatever their report says they reached.

## If staging is broken into

An alert that is not you, the team or the pentesters:

1. Stop it: `apps_enabled = false` and apply (every service to 0), or revoke the
   certificate the connection log shows.
2. Rotate in production every key `shared-keys.json` lists under `shared`.
3. Read what happened: the GuardDuty finding, CloudTrail (`/aws/cloudtrail/postiz-staging`),
   the load balancer's connection and access logs, the database's connection log.
4. Nothing else of production is in this account: no customer data, no
   production key, no trust between the accounts.
