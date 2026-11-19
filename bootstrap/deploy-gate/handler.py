"""The deploy gate: the only way a GitHub Actions run gets AWS credentials that can
change production (bootstrap/deploy-gate.tf, README "Deploy gate").

It sits behind an API Gateway HTTP API whose JWT authorizer has already checked
that the caller's token was signed by GitHub for this gate's audience. Any GitHub
repository can get such a token, so everything else is decided here, from the
token's claims:

  POST /open         {"code": "123456"}  approve this run attempt with a code from
                     the authenticator
  POST /credentials  one hour of credentials for the role of the job's GitHub
                     environment, only for an approved run attempt

Both need a manual run on the main branch of this repository, at the commit that
scripts/deploy-gate.sh trust recorded. A code is accepted once, and a few wrong
ones lock the gate until scripts/deploy-gate.sh reset.

The claims are trusted because API Gateway verified the token. Someone who can
invoke this function directly can make them up: only account admins can.
"""
import json
import os
import re
import time

import totp

ISSUER = "https://token.actions.githubusercontent.com"
SESSION_SECONDS = 3600  # the most a role assumed from another role can get
EXPIRED_STEPS = 120  # a real code up to an hour old is late, not a guess


class Refused(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


class Store:
    """The gate's DynamoDB table: three kinds of items under the key "id"."""

    def __init__(self, table):
        self.table = table

    def _get(self, key):
        return self.table.get_item(Key={"id": key}, ConsistentRead=True).get("Item")

    def trusted_sha(self):
        return (self._get("config") or {}).get("trusted_sha")

    def failures(self):
        return int((self._get("totp") or {}).get("failures", 0))

    def record_failure(self):
        result = self.table.update_item(
            Key={"id": "totp"},
            UpdateExpression="ADD #failures :one",
            ExpressionAttributeNames={"#failures": "failures"},
            ExpressionAttributeValues={":one": 1},
            ReturnValues="UPDATED_NEW",
        )
        return int(result["Attributes"]["failures"])

    def accept_step(self, step, max_failures):
        """Marks a code's step as used. False when this code or a later one was
        already used, or the gate locked in the meantime."""
        try:
            self.table.update_item(
                Key={"id": "totp"},
                UpdateExpression="SET #step = :step, #failures = :zero",
                ConditionExpression=(
                    "(attribute_not_exists(#step) OR #step < :step)"
                    " AND (attribute_not_exists(#failures) OR #failures < :max)"
                ),
                ExpressionAttributeNames={"#step": "last_step", "#failures": "failures"},
                ExpressionAttributeValues={":step": step, ":zero": 0, ":max": max_failures},
            )
            return True
        except self.table.meta.client.exceptions.ConditionalCheckFailedException:
            return False

    def approval(self, run):
        return self._get("run#" + run)

    def approve(self, run, item):
        self.table.put_item(Item={"id": "run#" + run, **item})


class Gate:
    def __init__(self, store, read_secret, assume_role, config, now=time.time, log=print):
        self.store = store
        self.read_secret = read_secret
        self.assume_role = assume_role
        self.config = config
        self.now = now
        self.log = log

    # --- who is asking -----------------------------------------------------

    def caller(self, claims):
        """Checks the token's claims and returns the run attempt and its target."""
        config = self.config
        expected = {
            "iss": ISSUER,
            "aud": config["audience"],
            "repository_id": config["repository_id"],
            "repository_owner_id": config["repository_owner_id"],
            "ref": config["ref"],
            "event_name": "workflow_dispatch",
        }
        for claim, value in expected.items():
            if str(claims.get(claim, "")) != value:
                raise Refused(403, f"not a manual run on {config['ref']} of this repository ({claim})")

        environment = str(claims.get("environment", ""))
        target = config["targets"].get(environment)
        if target is None:
            raise Refused(403, "the job runs in no GitHub environment that has a role")

        run_id, attempt = str(claims.get("run_id", "")), str(claims.get("run_attempt", ""))
        if not (run_id.isdigit() and attempt.isdigit()):
            raise Refused(403, "the token names no run")

        # the commit of the run, and of its workflow file when the token carries it
        commits = {str(claims[c]) for c in ("sha", "workflow_sha") if claims.get(c)}
        trusted = self.store.trusted_sha()
        if not trusted:
            raise Refused(403, "no commit is trusted yet: run scripts/deploy-gate.sh trust")
        if commits != {trusted}:
            shown = ", ".join(sorted(c[:12] for c in commits)) or "unknown"
            raise Refused(
                403,
                f"this run is at commit {shown}, the trusted one is {trusted[:12]}: "
                "review what changed and run scripts/deploy-gate.sh trust",
            )

        return {
            "run": f"{run_id}#{attempt}",
            "run_id": run_id,
            "attempt": attempt,
            "environment": environment,
            "target": target,
            "sha": trusted,
            "actor": str(claims.get("actor", "")),
        }

    def valid_approval(self, caller):
        item = self.store.approval(caller["run"])
        if not item or int(item["expires"]) <= self.now():
            return None
        if item.get("environment") != caller["environment"] or item.get("sha") != caller["sha"]:
            return None
        return item

    # --- routes ------------------------------------------------------------

    def open(self, claims, body):
        caller = self.caller(claims)
        approval = self.valid_approval(caller)
        if approval:  # a retried request: the code was already checked
            return self._opened(caller, int(approval["expires"]))

        code = "".join(str(body.get("code", "")).split())
        if not re.fullmatch(r"\d{6}", code):
            raise Refused(400, "the code is the 6 digits the authenticator shows")

        max_failures = self.config["max_failures"]
        if self.store.failures() >= max_failures:
            self._event("locked", caller)
            raise Refused(423, self._locked())

        secret = self.read_secret()
        step = totp.matching_step(secret, code, self.now())
        if step is None:
            # A run that waited (a slow runner, another deploy in front of it) sends
            # a code that was right a while ago. That is not a guess, so it does not
            # count towards the lock: 120 of a million codes get this answer.
            if totp.matching_step(secret, code, self.now(), past=EXPIRED_STEPS, future=0) is not None:
                self._event("expired", caller)
                raise Refused(403, "this code has expired, codes are good for about a minute: start a new run with a new one")
            raise Refused(403, self._wrong(caller, "wrong code"))
        if not self.store.accept_step(step, max_failures):
            raise Refused(403, self._wrong(caller, "this code was already used, wait for the next one"))

        expires = int(self.now()) + caller["target"]["approval_seconds"]
        self.store.approve(
            caller["run"],
            {
                "environment": caller["environment"],
                "sha": caller["sha"],
                "actor": caller["actor"],
                "expires": expires,
                "ttl": expires + 30 * 86400,
            },
        )
        self._event("opened", caller, expires=expires)
        return self._opened(caller, expires)

    def credentials(self, claims, _body):
        caller = self.caller(claims)
        if not self.valid_approval(caller):
            raise Refused(
                403,
                "this run attempt has no approval (a re-run needs its own): "
                "start a new run with a new code",
            )
        credentials = self.assume_role(
            caller["target"]["role_arn"],
            f"github-{caller['run_id']}-{caller['attempt']}",
            SESSION_SECONDS,
        )
        self._event("credentials", caller)
        return {"ok": True, "credentials": credentials}

    # --- helpers -----------------------------------------------------------

    def _opened(self, caller, expires):
        until = time.strftime("%H:%M UTC", time.gmtime(expires))
        return {"ok": True, "message": f"approved: the {caller['environment']} role is open to this run until {until}"}

    def _wrong(self, caller, reason):
        failures = self.store.record_failure()
        self._event("refused", caller, reason=reason, failures=failures)
        max_failures = self.config["max_failures"]
        if failures >= max_failures:
            return f"{reason}. {self._locked()}"
        return f"{reason} ({failures} of {max_failures} before the gate locks)"

    def _locked(self):
        return "The gate is locked after too many wrong codes: scripts/deploy-gate.sh reset"

    def _event(self, name, caller, **more):
        self.log(
            json.dumps(
                {
                    "event": name,
                    "run_id": caller["run_id"],
                    "attempt": caller["attempt"],
                    "environment": caller["environment"],
                    "sha": caller["sha"],
                    "actor": caller["actor"],
                    **more,
                }
            )
        )


def respond(status, payload):
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json", "cache-control": "no-store"},
        "body": json.dumps(payload),
    }


def handle(gate, event):
    routes = {"POST /open": gate.open, "POST /credentials": gate.credentials}
    route = routes.get(event.get("routeKey"))
    if route is None:
        return respond(404, {"ok": False, "message": "unknown route"})
    try:
        claims = event["requestContext"]["authorizer"]["jwt"]["claims"]
    except (KeyError, TypeError):
        return respond(401, {"ok": False, "message": "no verified token"})
    try:
        body = json.loads(event.get("body") or "{}")
        if not isinstance(body, dict):
            raise ValueError
    except ValueError:
        return respond(400, {"ok": False, "message": "the body must be a JSON object"})
    try:
        return respond(200, route(claims, body))
    except Refused as refused:
        return respond(refused.status, {"ok": False, "message": refused.message})


_gate = None


def _aws_gate():
    import boto3  # in the Lambda runtime; the tests never get here

    region = os.environ["AWS_REGION"]
    secrets = boto3.client("secretsmanager")
    sts = boto3.client("sts", region_name=region, endpoint_url=f"https://sts.{region}.amazonaws.com")

    def read_secret():
        return secrets.get_secret_value(SecretId=os.environ["SECRET_ID"])["SecretString"]

    def assume_role(role_arn, session_name, seconds):
        c = sts.assume_role(RoleArn=role_arn, RoleSessionName=session_name, DurationSeconds=seconds)["Credentials"]
        return {
            "AccessKeyId": c["AccessKeyId"],
            "SecretAccessKey": c["SecretAccessKey"],
            "SessionToken": c["SessionToken"],
            "Expiration": c["Expiration"].strftime("%Y-%m-%dT%H:%M:%SZ"),
        }

    config = {
        "audience": os.environ["AUDIENCE"],
        "repository_id": os.environ["REPOSITORY_ID"],
        "repository_owner_id": os.environ["REPOSITORY_OWNER_ID"],
        "ref": os.environ["REF"],
        "max_failures": int(os.environ["MAX_FAILURES"]),
        "targets": json.loads(os.environ["TARGETS"]),
    }
    store = Store(boto3.resource("dynamodb").Table(os.environ["TABLE"]))
    return Gate(store, read_secret, assume_role, config)


def handler(event, _context):
    global _gate
    if _gate is None:
        _gate = _aws_gate()
    return handle(_gate, event)
