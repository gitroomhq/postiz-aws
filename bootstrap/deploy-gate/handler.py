"""The deploy gate: the only way a GitHub Actions run gets AWS credentials that can
change production (bootstrap/deploy-gate.tf, README "Deploy gate").

It sits behind an API Gateway HTTP API whose JWT authorizer has already checked
that the caller's token was signed by GitHub for this gate's audience. Any GitHub
repository can get such a token, so everything else is decided here, from the
token's claims:

  POST /open         {"code": "123456"}  approve this run attempt with a code from
                     the authenticator of the person who started the run
  POST /credentials  one hour of credentials for the role of the job's GitHub
                     environment, only for an approved run attempt

Both need a manual run on the main branch of a repository the gate serves, at
the commit that scripts/deploy-gate.sh trust recorded for that repository,
started by someone scripts/deploy-gate.sh enroll gave an authenticator and the
right the environment asks for. Everyone has their own secret, tied to their
GitHub account by its numeric id: a code only opens runs its owner started, in
whichever of the repositories. A code is accepted once, and a few wrong ones lock
that person out until scripts/deploy-gate.sh reset.

The gate serves the repository holding this code and any other of the same owner
that bootstrap names (REPOSITORIES): each has its own trusted commit, and its
GitHub environments name the roles its runs get.

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
# what the log says about who asked, from GitHub's token
LOGGED_CLAIMS = (
    "repository",
    "ref",
    "sha",
    "workflow_sha",
    "event_name",
    "environment",
    "run_id",
    "run_attempt",
    "actor",
    "actor_id",
    "job_workflow_ref",
)


class Refused(Exception):
    """A request the gate turns down. `message` goes to the caller; `event`,
    `reason` and `details` go to the log."""

    def __init__(self, status, message, event="refused", reason=None, **details):
        super().__init__(message)
        self.status = status
        self.message = message
        self.event = event
        self.details = {"reason": reason or message, **details}


class RoleNotAssumable(Exception):
    """AWS did not let the gate assume a target's role."""


class Store:
    """The gate's DynamoDB table, three kinds of items under the key "id":
    "trust#<GitHub repository id>" (that repository's trusted commit),
    "user#<GitHub user id>" (someone who may start runs: their rights, wrong codes
    and last used code) and "run#<run>#<attempt>" (an approval)."""

    def __init__(self, table):
        self.table = table

    def _get(self, key):
        return self.table.get_item(Key={"id": key}, ConsistentRead=True).get("Item")

    def trusted_sha(self, repository_id):
        return (self._get("trust#" + repository_id) or {}).get("trusted_sha")

    def user(self, actor_id):
        return self._get("user#" + actor_id)

    # Both updates need the item to exist: an update of a missing item would
    # create it, and someone removed a moment ago must stay removed.

    def record_failure(self, actor_id):
        """Counts a wrong code of this user. None when they were removed meanwhile."""
        try:
            result = self.table.update_item(
                Key={"id": "user#" + actor_id},
                UpdateExpression="ADD #failures :one",
                ConditionExpression="attribute_exists(#id)",
                ExpressionAttributeNames={"#id": "id", "#failures": "failures"},
                ExpressionAttributeValues={":one": 1},
                ReturnValues="UPDATED_NEW",
            )
        except self.table.meta.client.exceptions.ConditionalCheckFailedException:
            return None
        return int(result["Attributes"]["failures"])

    def accept_step(self, actor_id, step, max_failures):
        """Marks a code's step as used by this user. False when this code or a later
        one was already used, or they were locked out or removed in the meantime."""
        try:
            self.table.update_item(
                Key={"id": "user#" + actor_id},
                UpdateExpression="SET #step = :step, #failures = :zero",
                ConditionExpression=(
                    "attribute_exists(#id)"
                    " AND (attribute_not_exists(#step) OR #step < :step)"
                    " AND (attribute_not_exists(#failures) OR #failures < :max)"
                ),
                ExpressionAttributeNames={"#id": "id", "#step": "last_step", "#failures": "failures"},
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
            "repository_owner_id": config["repository_owner_id"],
            "ref": config["ref"],
            "event_name": "workflow_dispatch",
        }
        for claim, value in expected.items():
            if str(claims.get(claim, "")) != value:
                raise Refused(403, f"not a manual run on {config['ref']} of a repository the gate serves ({claim})")

        # the repository by its id: a name can be given to another repository
        repository_id = str(claims.get("repository_id", ""))
        repository = config["repositories"].get(repository_id)
        if repository is None:
            raise Refused(403, "not a repository the gate serves (repository_id)")

        environment = str(claims.get("environment", ""))
        target = repository["targets"].get(environment)
        if target is None:
            raise Refused(403, f"the job runs in no GitHub environment of {repository['name']} that has a role")

        run_id, attempt = str(claims.get("run_id", "")), str(claims.get("run_attempt", ""))
        if not (run_id.isdigit() and attempt.isdigit()):
            raise Refused(403, "the token names no run")

        # the commit of the run, and of its workflow file when the token carries it
        commits = {str(claims[c]) for c in ("sha", "workflow_sha") if claims.get(c)}
        trusted = self.store.trusted_sha(repository_id)
        if not trusted:
            raise Refused(
                403,
                f"no commit of {repository['name']} is trusted yet: "
                "run scripts/deploy-gate.sh trust in a clone of it",
            )
        if commits != {trusted}:
            shown = ", ".join(sorted(c[:12] for c in commits)) or "unknown"
            raise Refused(
                403,
                f"this run is at commit {shown} of {repository['name']}, the trusted one is {trusted[:12]}: "
                "review what changed and run scripts/deploy-gate.sh trust in a clone of it",
            )

        # who started the run: GitHub's numeric id, a login can be renamed and reused
        actor = str(claims.get("actor", "")) or "this account"
        actor_id = str(claims.get("actor_id", ""))
        user = self.store.user(actor_id) if actor_id.isdigit() else None
        if not user:
            raise Refused(
                403,
                f"{actor} has no authenticator for the deploy gate: "
                f"an admin gives one with scripts/deploy-gate.sh enroll {actor}",
            )
        # What the person may do is stored as the environments of the first
        # repository, "deploy" and "production" (terraform apply). An environment
        # of another repository says which of the two it asks for.
        right = target.get("right", environment)
        if right not in (user.get("environments") or ()):
            what = "run terraform apply" if right == "production" else f"start runs in the {environment} environment"
            raise Refused(
                403,
                f"{actor} may not {what}: an admin changes that with scripts/deploy-gate.sh grant",
            )

        return {
            "run": f"{run_id}#{attempt}",
            "run_id": run_id,
            "attempt": attempt,
            "repository_id": repository_id,
            "environment": environment,
            "target": target,
            "sha": trusted,
            "actor": actor,
            "actor_id": actor_id,
            "failures": int(user.get("failures", 0)),
        }

    def valid_approval(self, caller):
        item = self.store.approval(caller["run"])
        if not item or int(item["expires"]) <= self.now():
            return None
        for field in ("repository_id", "environment", "sha", "actor_id"):
            if item.get(field) != caller[field]:
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
        if caller["failures"] >= max_failures:
            raise Refused(423, self._locked(caller), event="locked")

        secret = self.read_secret(caller["actor_id"])
        if not secret:
            raise Refused(
                403,
                f"{caller['actor']}'s authenticator was never stored: "
                f"scripts/deploy-gate.sh enroll {caller['actor']} --rotate",
            )
        step = totp.matching_step(secret, code, self.now())
        if step is None:
            # A run that waited (a slow runner, another deploy in front of it) sends
            # a code that was right a while ago. That is not a guess, so it does not
            # count towards the lock: 120 of a million codes get this answer.
            if totp.matching_step(secret, code, self.now(), past=EXPIRED_STEPS, future=0) is not None:
                raise Refused(
                    403,
                    "this code has expired, codes are good for about a minute: start a new run with a new one",
                    event="expired",
                )
            raise self._wrong(caller, "wrong code")
        if not self.store.accept_step(caller["actor_id"], step, max_failures):
            raise self._wrong(caller, "this code was already used, wait for the next one")

        expires = int(self.now()) + caller["target"]["approval_seconds"]
        self.store.approve(
            caller["run"],
            {
                "repository_id": caller["repository_id"],
                "environment": caller["environment"],
                "sha": caller["sha"],
                "actor": caller["actor"],
                "actor_id": caller["actor_id"],
                "expires": expires,
                "ttl": expires + 30 * 86400,
            },
        )
        self.record("opened", claims, expires=expires)
        return self._opened(caller, expires)

    def credentials(self, claims, _body):
        caller = self.caller(claims)
        if not self.valid_approval(caller):
            raise Refused(
                403,
                "this run attempt has no approval (a re-run needs its own): "
                "start a new run with a new code",
            )
        role_arn = caller["target"]["role_arn"]
        try:
            credentials = self.assume_role(role_arn, f"github-{caller['run_id']}-{caller['attempt']}", SESSION_SECONDS)
        except RoleNotAssumable as error:
            # a role that was just added, before the stack that owns it was applied
            raise Refused(
                403,
                f"the gate cannot hand out {role_arn.rsplit('/', 1)[-1]} ({error}): the role has to trust "
                "the gate's role, which the apply of the stack that owns the role does",
                reason=f"cannot assume the role: {error}",
            )
        self.record("credentials", claims)
        return {"ok": True, "credentials": credentials}

    # --- helpers -----------------------------------------------------------

    def _opened(self, caller, expires):
        until = time.strftime("%H:%M UTC", time.gmtime(expires))
        return {"ok": True, "message": f"approved: the {caller['environment']} role is open to this run until {until}"}

    def _wrong(self, caller, reason):
        """Counts a wrong code of the person who started the run and says how many
        are left. Only they are locked out, everyone else goes on."""
        failures = self.store.record_failure(caller["actor_id"])
        max_failures = self.config["max_failures"]
        if failures is None:  # removed while this request was running
            return Refused(403, f"{caller['actor']} has no authenticator for the deploy gate", reason=reason)
        if failures >= max_failures:
            message = f"{reason}. {self._locked(caller)}"
        else:
            message = f"{reason} ({failures} of {max_failures} before {caller['actor']} is locked out)"
        return Refused(403, message, reason=reason, failures=failures)

    def _locked(self, caller):
        actor = caller["actor"]
        return f"{actor} is locked out after too many wrong codes: an admin runs scripts/deploy-gate.sh reset {actor}"

    def record(self, event, claims, **more):
        """One log line for everything the gate decides, refusals included: which
        run asked, as GitHub's token names it. Never a code or a credential."""
        entry = {"event": event}
        for claim in LOGGED_CLAIMS:
            if claims.get(claim) is not None:
                entry[claim] = str(claims[claim])[:200]
        entry.update(more)
        self.log(json.dumps(entry))


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
        # also a run of another repository or at a commit nobody approved: the
        # log is where an attempt to get past the gate shows
        gate.record(refused.event, claims, route=event["routeKey"], status=refused.status, **refused.details)
        return respond(refused.status, {"ok": False, "message": refused.message})


_gate = None


def _aws_gate():
    import boto3  # in the Lambda runtime; the tests never get here
    from botocore.exceptions import ClientError

    region = os.environ["AWS_REGION"]
    secrets = boto3.client("secretsmanager")
    sts = boto3.client("sts", region_name=region, endpoint_url=f"https://sts.{region}.amazonaws.com")

    def read_secret(actor_id):
        # one secret per person, named after their GitHub user id (digits, checked)
        try:
            return secrets.get_secret_value(SecretId=os.environ["SECRET_PREFIX"] + actor_id)["SecretString"]
        except secrets.exceptions.ResourceNotFoundException:
            return None

    def assume_role(role_arn, session_name, seconds):
        try:
            c = sts.assume_role(RoleArn=role_arn, RoleSessionName=session_name, DurationSeconds=seconds)["Credentials"]
        except ClientError as error:
            raise RoleNotAssumable(error.response["Error"]["Code"])
        return {
            "AccessKeyId": c["AccessKeyId"],
            "SecretAccessKey": c["SecretAccessKey"],
            "SessionToken": c["SessionToken"],
            "Expiration": c["Expiration"].strftime("%Y-%m-%dT%H:%M:%SZ"),
        }

    config = {
        "audience": os.environ["AUDIENCE"],
        "repository_owner_id": os.environ["REPOSITORY_OWNER_ID"],
        "ref": os.environ["REF"],
        "max_failures": int(os.environ["MAX_FAILURES"]),
        # repository id -> {"name", "targets": {environment -> {"role_arn", "right", "approval_seconds"}}}
        "repositories": json.loads(os.environ["REPOSITORIES"]),
    }
    store = Store(boto3.resource("dynamodb").Table(os.environ["TABLE"]))
    return Gate(store, read_secret, assume_role, config)


def handler(event, _context):
    global _gate
    if _gate is None:
        _gate = _aws_gate()
    return handle(_gate, event)
