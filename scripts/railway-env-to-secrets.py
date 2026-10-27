#!/usr/bin/env python3
"""Copy the Railway environment of each Postiz service into its Secrets Manager secret.

  backend            <- "Backend  Postiz"
  mcp                <- "MCP"
  frontend           <- "Frontend"
  worker             <- "Worker"
  worker-2           <- "Worker 2"
  temporal-ui-auth   <- "Temporal Basic Auth" (USERNAME, PASSWORD)

Rewrites on the way:
  DATABASE_URL  pgbouncer.railway.internal:6432/railway -> <RDS main>:5432/postiz,
                drops ?pgbouncer=true (PgBouncer is gone); user, password,
                connection_limit, application_name and connect_timeout stay.
Dropped (Terraform sets them, or they only mean something on Railway):
  PORT, TEMPORAL_ADDRESS, REDIS_URL, PROXY_PASS, RAILWAY_*, NIXPACKS_*, RAILPACK_*,
  NO_CACHE, ENABLE_ALPINE_PRIVATE_NETWORKING

Dry run by default: prints key names and rewritten hosts, never values.
The Railway project and environment come from --project/--environment or
RAILWAY_PROJECT_ID/RAILWAY_ENVIRONMENT_ID, both in the dashboard URL
(railway.com/project/<project id>/...?environmentId=<environment id>).
  AWS_PROFILE=<profile> scripts/railway-env-to-secrets.py           # review
  AWS_PROFILE=<profile> scripts/railway-env-to-secrets.py --apply   # write the secrets
  scripts/railway-env-to-secrets.py --write-keys                    # refresh app-env-keys.json

Needs: `railway login` (token in ~/.railway/config.json) or RAILWAY_TOKEN,
the AWS CLI, and an applied environments/production (for secret ARNs and the
RDS address, read with `terraform output -json`).
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.request
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENV_DIR = os.path.join(REPO, 'environments', 'production')

RAILWAY_PROJECT = os.environ.get('RAILWAY_PROJECT_ID')
RAILWAY_ENVIRONMENT = os.environ.get('RAILWAY_ENVIRONMENT_ID')

SERVICES = {
    'backend': 'Backend Postiz',
    'mcp': 'MCP',
    'frontend': 'Frontend',
    'worker': 'Worker',
    'worker-2': 'Worker 2',
    'temporal-ui-auth': 'Temporal Basic Auth',
}

EXCLUDE = re.compile(r'^(RAILWAY_.*|NIXPACKS_.*|RAILPACK_.*|NO_CACHE|ENABLE_ALPINE_PRIVATE_NETWORKING|PORT|TEMPORAL_ADDRESS|REDIS_URL|PROXY_PASS)$')
RAILWAY_HOSTS = re.compile(r'railway\.internal|rlwy\.net|up\.railway\.app')


def railway(query, variables):
    token = os.environ.get('RAILWAY_TOKEN') or json.load(open(os.path.expanduser('~/.railway/config.json')))['user']['token']
    req = urllib.request.Request(
        'https://backboard.railway.com/graphql/v2',
        data=json.dumps({'query': query, 'variables': variables}).encode(),
        headers={'Content-Type': 'application/json', 'Authorization': f'Bearer {token}', 'User-Agent': 'postiz-aws'},
    )
    body = json.loads(urllib.request.urlopen(req, timeout=60).read())
    if body.get('errors'):
        sys.exit(f'Railway API error: {body["errors"][0]["message"]}')
    return body['data']


def railway_services():
    data = railway('query($id:String!){ project(id:$id){ services { edges { node { id name } } } } }', {'id': RAILWAY_PROJECT})
    # Railway names can carry double spaces ("Backend  Postiz")
    return {' '.join(e['node']['name'].split()): e['node']['id'] for e in data['project']['services']['edges']}


def railway_variables(service_id, unrendered=False):
    q = 'query($p:String!,$e:String!,$s:String){ variables(projectId:$p, environmentId:$e, serviceId:$s%s) }' % (', unrendered:true' if unrendered else '')
    return railway(q, {'p': RAILWAY_PROJECT, 'e': RAILWAY_ENVIRONMENT, 's': service_id})['variables']


def terraform_outputs():
    out = subprocess.run(['terraform', f'-chdir={ENV_DIR}', 'output', '-json'], capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f'terraform output failed (apply environments/production first):\n{out.stderr}')
    return {k: v['value'] for k, v in json.loads(out.stdout).items()}


def rewrite_database_url(value, rds_host):
    parts = urlsplit(value)
    query = [(k, v) for k, v in parse_qsl(parts.query, keep_blank_values=True) if k != 'pgbouncer']
    netloc = parts.netloc.rsplit('@', 1)
    userinfo = netloc[0] + '@' if len(netloc) == 2 else ''
    new = urlunsplit((parts.scheme, f'{userinfo}{rds_host}:5432', '/postiz', urlencode(query), ''))
    return new, f'{parts.hostname}:{parts.port}{parts.path} -> {rds_host}:5432/postiz, params {[k for k, _ in query]}'


def main():
    global RAILWAY_PROJECT, RAILWAY_ENVIRONMENT
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--apply', action='store_true', help='write the secrets (default: dry run)')
    ap.add_argument('--write-keys', action='store_true', help='regenerate environments/production/app-env-keys.json and exit')
    ap.add_argument('--only', help='comma-separated subset of services')
    ap.add_argument('--project', default=RAILWAY_PROJECT, help='Railway project id (or RAILWAY_PROJECT_ID)')
    ap.add_argument('--environment', default=RAILWAY_ENVIRONMENT, help='Railway environment id (or RAILWAY_ENVIRONMENT_ID)')
    args = ap.parse_args()
    if not args.project or not args.environment:
        sys.exit('set --project and --environment (or RAILWAY_PROJECT_ID / RAILWAY_ENVIRONMENT_ID)')
    RAILWAY_PROJECT, RAILWAY_ENVIRONMENT = args.project, args.environment

    ids = railway_services()
    wanted = args.only.split(',') if args.only else list(SERVICES)

    if args.write_keys:
        keys = {}
        for svc in SERVICES:
            names = railway_variables(ids[SERVICES[svc]], unrendered=True).keys()
            keys[svc] = sorted(k for k in names if not EXCLUDE.match(k))
        path = os.path.join(ENV_DIR, 'app-env-keys.json')
        with open(path, 'w') as f:
            json.dump(keys, f, indent=2)
            f.write('\n')
        print(f'wrote {path}; run terraform plan to see the task definition changes')
        return

    outputs = terraform_outputs()
    arns = outputs['app_secret_arns']
    rds_host = outputs['main_db_address']
    expected = json.load(open(os.path.join(ENV_DIR, 'app-env-keys.json')))

    for svc in wanted:
        values = railway_variables(ids[SERVICES[svc]])
        env = {k: v for k, v in values.items() if not EXCLUDE.match(k)}
        notes = []
        if 'DATABASE_URL' in env:
            env['DATABASE_URL'], note = rewrite_database_url(env['DATABASE_URL'], rds_host)
            notes.append(f'DATABASE_URL {note}')
        leftovers = sorted(k for k, v in env.items() if RAILWAY_HOSTS.search(v or ''))
        missing = sorted(set(expected.get(svc, [])) - set(env))
        extra = sorted(set(env) - set(expected.get(svc, [])))

        print(f'\n== {svc}: {len(env)} keys -> {arns[svc]}')
        for n in notes:
            print(f'   {n}')
        if leftovers:
            print(f'   WARNING still pointing at Railway: {leftovers}')
        if missing:
            print(f'   WARNING in app-env-keys.json but not on Railway (tasks will fail to start): {missing}')
        if extra:
            print(f'   NOTE on Railway but not in app-env-keys.json (not passed to the task): {extra}')

        if args.apply:
            with tempfile.NamedTemporaryFile('w', delete=False, suffix='.json') as f:
                os.chmod(f.name, 0o600)
                json.dump(env, f)
            try:
                subprocess.run(['aws', 'secretsmanager', 'put-secret-value', '--secret-id', arns[svc],
                                '--secret-string', f'file://{f.name}', '--query', 'VersionId', '--output', 'text'], check=True)
            finally:
                os.unlink(f.name)

    if not args.apply:
        print('\ndry run: nothing written, rerun with --apply')


if __name__ == '__main__':
    main()
