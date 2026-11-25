#!/usr/bin/env python3
"""Fill staging's app secrets (environments/staging/secrets.tf) without printing a value.

    staging-secrets.py fill        every key of app-env-keys.json in postiz/staging/{backend,
                                   frontend,worker}: values already set are kept; the rest gets
                                   staging's defaults (its URLs, a new JWT_SECRET), production's
                                   value for the keys shared-keys.json lists, or "" for you to
                                   fill in the console (ECS needs every key to exist)
    staging-secrets.py fill --recopy   the same, and copy shared-keys.json's keys from production
                                   again even where staging has a value (after a rotation there)
    staging-secrets.py missing     the keys still empty, per service (names only)

fill also clears any staging value that is production's own (12 characters or more,
so not a flag like "true") for a key shared-keys.json does not list: taking a key off
the list takes production's value out of staging at the next fill, and a production
credential pasted into staging by hand is caught the same way.

Profiles: STAGING_PROFILE (default postiz-staging) for the staging account, whose id
STAGING_ACCOUNT_ID must match; PRODUCTION_PROFILE (default postiz) to read production's
secrets (fill reads them every time, to catch production values that are not listed). Values go from one account to the
other inside this process and are never printed.

Some production values must never reach staging, whatever shared-keys.json says: the
script refuses them (NEVER_COPY below).
"""

import argparse
import json
import os
import re
import secrets
import string
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
STAGING_DIR = os.path.join(os.path.dirname(HERE), "environments", "staging")
REGION = os.environ.get("AWS_REGION", "us-east-2")
STAGING_PREFIX = "postiz/staging"
PRODUCTION_PREFIX = "postiz/production"

# where each staging service's production values come from, first match wins
PRODUCTION_SOURCES = {
    "backend": ["backend", "mcp"],
    "frontend": ["frontend"],
    "worker": ["worker", "worker-2"],
}

FRONTEND = "https://platform.getpostiz.com"
DEFAULTS = {
    "FRONTEND_URL": FRONTEND,
    "MAIN_URL": FRONTEND,
    "NEXT_PUBLIC_BACKEND_URL": "https://api.getpostiz.com",
    "MCP_URL": "https://mcp.getpostiz.com",
    # inside the VPC: the load balancer asks for a client certificate (locals.tf)
    "BACKEND_INTERNAL_URL": "http://backend.postiz.internal:8080",
    "NODE_ENV": "production",
    # under the 2048 MiB Fargate tasks of backend and worker (postiz.tf)
    "NODE_OPTIONS": "--max-old-space-size=1536",
    "EMAIL_FROM_ADDRESS": "no-reply@getpostiz.com",
    "EMAIL_FROM_NAME": "Postiz Staging",
}

# Never copied from production. Sharing these would hand staging (and whoever
# breaks into it) control over production, or mix staging into production's
# money, analytics or bots.
NEVER_COPY = {
    # sign in as any production user
    "JWT_SECRET",
    # payments and billing: test mode / staging's own
    "STRIPE_SECRET_KEY", "STRIPE_PUBLISHABLE_KEY", "STRIPE_SIGNING_KEY", "STRIPE_SIGNING_KEY_CONNECT", "STRIPE_DISCOUNT_ID",
    "REVENUECAT_SECRET_KEY", "REVENUECAT_WEBHOOK_SECRET", "NOWPAYMENTS_API_KEY",
    "APPSUMO_API_KEY", "APPSUMO_CLIENT_ID", "APPSUMO_CLIENT_SECRET",
    # customers' uploaded media: staging gets its own bucket
    "CLOUDFLARE_ACCESS_KEY", "CLOUDFLARE_SECRET_ACCESS_KEY", "CLOUDFLARE_BUCKETNAME", "CLOUDFLARE_BUCKET_URL",
    "CLOUDFLARE_ACCOUNT_ID", "NEXT_PUBLIC_UPLOAD_STATIC_DIRECTORY",
    # an identity, not an app: the Farcaster account's key, the bots' tokens
    # (a shared Telegram bot would also consume production's getUpdates)
    "NEYNAR_APP_MNEMONIC", "TELEGRAM_TOKEN", "DISCORD_BOT_TOKEN_ID",
    # webhook and partner secrets: forged calls to production
    "SLACK_SIGNING_SECRET", "LEADJOURNEY_POSTBACK_SECRET", "LEADJOURNEY_POSTBACK_URL", "AGENT_API_KEY", "AGENT_MEDIA_SSO_KEY",
    # production's email, error tracking and analytics
    "RESEND_API_KEY", "SENTRY_AUTH_TOKEN", "NEXT_PUBLIC_SENTRY_DSN", "FACEBOOK_PIXEL_ACCESS_TOKEN",
    "NEXT_PUBLIC_FACEBOOK_PIXEL", "NEXT_PUBLIC_GTM_ID", "NEXT_PUBLIC_POSTHOG_KEY", "NEXT_PUBLIC_POSTHOG_HOST",
    "NEXT_PUBLIC_TOLT", "DATAFAST_API_KEY", "DATAFAST_WEBSITE_ID", "CHATBASE_TOKEN",
    # domain challenges and URLs that name production
    "OPENAI_APP_CHALLANGE", "MUSE_CHALLENGE", "FRONTEND_URL", "MAIN_URL", "NEXT_PUBLIC_BACKEND_URL", "MCP_URL",
    "BACKEND_INTERNAL_URL", "NEXT_PUBLIC_OVERRIDE_BACKEND_URL", "DATABASE_URL",
}


def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def aws(profile, *args, allow_missing=False):
    p = subprocess.run(
        ["aws", "--profile", profile, "--region", REGION, "--output", "json", *args],
        text=True, capture_output=True,
    )
    if p.returncode != 0:
        if allow_missing and ("ResourceNotFoundException" in p.stderr or "AWSCURRENT" in p.stderr):
            return None
        die(f"aws {' '.join(args[:2])} ({profile}) failed: {p.stderr.strip()}")
    return json.loads(p.stdout) if p.stdout.strip() else {}


def read_secret(profile, secret_id):
    out = aws(profile, "secretsmanager", "get-secret-value", "--secret-id", secret_id, "--query", "SecretString", allow_missing=True)
    if out is None:
        return None
    value = json.loads(out)
    if not isinstance(value, dict):
        die(f"{secret_id} does not hold a JSON object")
    return value


def write_secret(profile, secret_id, value):
    fd, path = tempfile.mkstemp(prefix="staging-secret-")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(value, f)
        aws(profile, "secretsmanager", "put-secret-value", "--secret-id", secret_id, "--secret-string", f"file://{path}")
    finally:
        os.remove(path)


def load_json(name):
    with open(os.path.join(STAGING_DIR, name)) as f:
        return json.load(f)


def check_staging(profile):
    want = os.environ.get("STAGING_ACCOUNT_ID", "")
    if not re.fullmatch(r"\d{12}", want):
        die("set STAGING_ACCOUNT_ID to the staging account's id")
    have = aws(profile, "sts", "get-caller-identity")["Account"]
    if have != want:
        die(f"{profile} is account {have}, not staging ({want})")
    return have


def cmd_fill(args):
    staging_profile = os.environ.get("STAGING_PROFILE", "postiz-staging")
    production_profile = os.environ.get("PRODUCTION_PROFILE", "postiz")
    staging_account = check_staging(staging_profile)

    keys = load_json("app-env-keys.json")
    copy = load_json("shared-keys.json")
    copied_names = set(copy.get("settings", [])) | set(copy.get("shared", []))
    refused = sorted(copied_names & NEVER_COPY)
    if refused:
        die(f"shared-keys.json lists keys that must never be copied from production: {', '.join(refused)}")
    unknown = sorted(copied_names - {k for v in keys.values() for k in v})
    if unknown:
        die(f"shared-keys.json lists keys no staging service has: {', '.join(unknown)}")

    production = {}
    if aws(production_profile, "sts", "get-caller-identity")["Account"] == staging_account:
        die(f"PRODUCTION_PROFILE ({production_profile}) points at the staging account")
    for svc, sources in PRODUCTION_SOURCES.items():
        merged = {}
        for source in sources:
            value = read_secret(production_profile, f"{PRODUCTION_PREFIX}/{source}") or {}
            for k, v in value.items():
                merged.setdefault(k, v)
        production[svc] = merged
    production_values = {v for values in production.values() for v in values.values() if len(v) >= 12}

    current = {svc: read_secret(staging_profile, f"{STAGING_PREFIX}/{svc}") or {} for svc in keys}
    # one JWT_SECRET for every staging service, never production's
    jwt = next((current[s]["JWT_SECRET"] for s in current if current[s].get("JWT_SECRET") and current[s]["JWT_SECRET"] not in production_values), None)
    jwt = jwt or "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(64))

    for svc, names in keys.items():
        old = current[svc]
        new = {}
        report = {"kept": [], "default": [], "production": [], "generated": [], "empty": [], "dropped": [], "cleared": []}
        for k in names:
            have = old.get(k, "")
            if k in copied_names and (args.recopy or not have) and production[svc].get(k, "") != "":
                new[k] = production[svc][k]
                report["production"].append(k)
            elif have and k not in copied_names and k not in DEFAULTS and have in production_values:
                new[k] = ""
                report["cleared"].append(k)
            elif have:
                new[k] = have
                report["kept"].append(k)
            elif k in DEFAULTS:
                new[k] = DEFAULTS[k]
                report["default"].append(k)
            elif k == "JWT_SECRET":
                new[k] = jwt
                report["generated"].append(k)
            else:
                new[k] = ""
                report["empty"].append(k)
        report["dropped"] = sorted(set(old) - set(names))
        if new != old:
            write_secret(staging_profile, f"{STAGING_PREFIX}/{svc}", new)
        print(f"{STAGING_PREFIX}/{svc}: {len(report['kept'])} kept, {len(report['default'])} staging defaults, "
              f"{len(report['generated'])} generated, {len(report['production'])} from production, {len(report['empty'])} empty"
              + (" (unchanged)" if new == old else ""))
        if report["production"]:
            print(f"  from production: {', '.join(report['production'])}")
        if report["cleared"]:
            print(f"  cleared, production's value but not in shared-keys.json: {', '.join(report['cleared'])}")
        if report["dropped"]:
            print(f"  removed, no longer in app-env-keys.json: {', '.join(report['dropped'])}")
    print("Fill the empty ones in the console (Secrets Manager, staging account), see: staging-secrets.py missing")


def cmd_missing(_args):
    staging_profile = os.environ.get("STAGING_PROFILE", "postiz-staging")
    check_staging(staging_profile)
    for svc, names in load_json("app-env-keys.json").items():
        value = read_secret(staging_profile, f"{STAGING_PREFIX}/{svc}") or {}
        empty = [k for k in names if not value.get(k)]
        print(f"{svc}: {len(empty)} empty")
        for k in empty:
            print(f"  {k}")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="command", required=True)
    f = sub.add_parser("fill")
    f.add_argument("--recopy", action="store_true")
    f.set_defaults(func=cmd_fill)
    sub.add_parser("missing").set_defaults(func=cmd_missing)
    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
