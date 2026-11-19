"""python3 -m unittest discover -s bootstrap/deploy-gate
Standard library only: the table, the secret and STS are replaced by fakes."""
import json
import unittest

import handler
import totp

SECRET = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"  # "12345678901234567890", the RFC 6238 test key
OTHER_SECRET = "JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP"
ME, COLLEAGUE, STRANGER = "1001", "2002", "3003"  # GitHub user ids
TRUSTED = "a" * 40
OTHER = "b" * 40
CONFIG = {
    "audience": "postiz-deploy-gate",
    "repository_id": "1436140501",
    "repository_owner_id": "128401275",
    "ref": "refs/heads/main",
    "max_failures": 5,
    "targets": {
        "deploy": {"role_arn": "arn:aws:iam::123456789012:role/deploy", "approval_seconds": 5400},
        "production": {"role_arn": "arn:aws:iam::123456789012:role/apply", "approval_seconds": 7200},
    },
}


class FakeStore:
    def __init__(self, trusted=TRUSTED):
        self.trusted = trusted
        self.users = {
            ME: {"login": "someone", "environments": ["deploy", "production"]},
            COLLEAGUE: {"login": "colleague", "environments": ["deploy"]},
        }
        self.approvals = {}

    def trusted_sha(self):
        return self.trusted

    def user(self, actor_id):
        item = self.users.get(actor_id)
        return dict(item) if item else None

    def record_failure(self, actor_id):
        if actor_id not in self.users:
            return None
        user = self.users[actor_id]
        user["failures"] = user.get("failures", 0) + 1
        return user["failures"]

    def accept_step(self, actor_id, step, max_failures):
        user = self.users.get(actor_id)
        if user is None or user.get("failures", 0) >= max_failures or user.get("last_step", -1) >= step:
            return False
        user["last_step"], user["failures"] = step, 0
        return True

    def fails(self, actor_id=ME):
        return self.users[actor_id].get("failures", 0)

    def approval(self, run):
        return self.approvals.get(run)

    def approve(self, run, item):
        self.approvals[run] = item


class GateTest(unittest.TestCase):
    def setUp(self):
        self.clock = 1_800_000_000
        self.store = FakeStore()
        self.assumed = []
        self.events = []

        def assume_role(role_arn, session_name, seconds):
            self.assumed.append((role_arn, session_name, seconds))
            return {"AccessKeyId": "ASIA", "SecretAccessKey": "s", "SessionToken": "t", "Expiration": "2027-01-15T08:00:00Z"}

        self.secrets = {ME: SECRET, COLLEAGUE: OTHER_SECRET}
        self.gate = handler.Gate(
            self.store, self.secrets.get, assume_role, CONFIG, now=lambda: self.clock, log=self.events.append
        )

    def claims(self, **changes):
        claims = {
            "iss": handler.ISSUER,
            "aud": "postiz-deploy-gate",
            "repository_id": "1436140501",
            "repository_owner_id": "128401275",
            "ref": "refs/heads/main",
            "event_name": "workflow_dispatch",
            "environment": "deploy",
            "run_id": "777",
            "run_attempt": "1",
            "sha": TRUSTED,
            "workflow_sha": TRUSTED,
            "actor": "someone",
            "actor_id": ME,
        }
        claims.update(changes)
        return {k: v for k, v in claims.items() if v is not None}

    def call(self, route, claims=None, body=None):
        event = {
            "routeKey": f"POST /{route}",
            "requestContext": {"authorizer": {"jwt": {"claims": claims if claims is not None else self.claims()}}},
            "body": json.dumps(body if body is not None else {}),
        }
        response = handler.handle(self.gate, event)
        return response["statusCode"], json.loads(response["body"])

    def code(self, offset=0, secret=SECRET):
        return totp.code_at(secret, self.clock // 30 + offset)

    def colleague(self, **changes):
        return self.claims(actor="colleague", actor_id=COLLEAGUE, **changes)

    def open(self, **claims):
        return self.call("open", self.claims(**claims), {"code": self.code()})

    # --- the codes -----------------------------------------------------------

    def test_rfc_6238_vectors(self):
        for at, expected in ((59, "287082"), (1111111109, "081804"), (1234567890, "005924"), (2000000000, "279037")):
            self.assertEqual(totp.code_at(SECRET, at // 30), expected)

    def test_accepts_a_code_up_to_two_steps_old_and_one_ahead(self):
        for offset, ok in ((-3, False), (-2, True), (-1, True), (0, True), (1, True), (2, False)):
            found = totp.matching_step(SECRET, self.code(offset), self.clock)
            self.assertEqual(found is not None, ok, offset)

    # --- opening -------------------------------------------------------------

    def test_a_valid_code_approves_the_run_and_gives_credentials(self):
        status, body = self.open()
        self.assertEqual((status, body["ok"]), (200, True))
        status, body = self.call("credentials")
        self.assertEqual(status, 200)
        self.assertEqual(body["credentials"]["AccessKeyId"], "ASIA")
        self.assertEqual(self.assumed, [("arn:aws:iam::123456789012:role/deploy", "github-777-1", 3600)])

    def test_the_environment_picks_the_role(self):
        self.open(environment="production")
        self.call("credentials", self.claims(environment="production"))
        self.assertEqual(self.assumed[0][0], "arn:aws:iam::123456789012:role/apply")
        # the approval is for that environment only
        status, _ = self.call("credentials", self.claims(environment="deploy"))
        self.assertEqual(status, 403)

    def test_no_credentials_without_an_approval(self):
        status, body = self.call("credentials")
        self.assertEqual(status, 403)
        self.assertIn("new code", body["message"])
        self.assertEqual(self.assumed, [])

    def test_a_code_works_once(self):
        self.assertEqual(self.open()[0], 200)
        status, body = self.open(run_id="778")
        self.assertEqual(status, 403)
        self.assertIn("already used", body["message"])
        self.assertEqual(self.call("credentials", self.claims(run_id="778"))[0], 403)

    def test_an_older_code_is_refused_after_a_newer_one(self):
        older = self.code(-1)
        self.assertEqual(self.open()[0], 200)
        status, _ = self.call("open", self.claims(run_id="778"), {"code": older})
        self.assertEqual(status, 403)

    def test_a_repeated_open_of_an_approved_run_checks_no_code(self):
        self.assertEqual(self.open()[0], 200)
        status, body = self.call("open", body={"code": "000000"})
        self.assertEqual((status, body["ok"]), (200, True))
        self.assertEqual(self.store.fails(), 0)

    def test_a_rerun_needs_its_own_approval(self):
        self.open()
        self.assertEqual(self.call("credentials", self.claims(run_attempt="2"))[0], 403)

    def test_another_run_cannot_use_the_approval(self):
        self.open()
        self.assertEqual(self.call("credentials", self.claims(run_id="999"))[0], 403)

    def test_the_approval_ends(self):
        self.open()
        self.clock += 5400
        self.assertEqual(self.call("credentials")[0], 403)

    def test_spaces_in_the_code_are_fine(self):
        code = self.code()
        status, _ = self.call("open", body={"code": f"{code[:3]} {code[3:]}"})
        self.assertEqual(status, 200)

    def test_a_malformed_code_is_not_a_guess(self):
        for bad in ("", "12345", "1234567", "abcdef", None, 12):
            status, _ = self.call("open", body={"code": bad})
            self.assertEqual(status, 400, bad)
        self.assertEqual(self.store.fails(), 0)

    def test_a_code_that_is_too_old_is_refused_without_counting(self):
        for offset in (-3, -60, -120):
            status, body = self.call("open", body={"code": self.code(offset)})
            self.assertEqual(status, 403, offset)
            self.assertIn("expired", body["message"])
        self.assertEqual((self.store.fails(), self.store.approvals), (0, {}))

    # --- wrong codes -----------------------------------------------------------

    def wrong(self):
        recent = {self.code(offset) for offset in range(-handler.EXPIRED_STEPS, 2)}
        return next(c for c in ("000000", "111111", "222222", "333333") if c not in recent)

    def test_wrong_codes_lock_that_person_out_also_with_the_right_code(self):
        for n in range(1, 6):
            status, body = self.call("open", body={"code": self.wrong()})
            self.assertEqual(status, 403)
        self.assertIn("locked out", body["message"])
        self.assertIn("reset someone", body["message"])
        status, body = self.open()
        self.assertEqual(status, 423)
        self.assertEqual(self.store.approvals, {})
        self.assertEqual(self.store.fails(), 5)  # someone locked out is counted no further
        # everyone else goes on
        status, _ = self.call("open", self.colleague(run_id="900"), {"code": self.code(secret=OTHER_SECRET)})
        self.assertEqual(status, 200)

    def test_a_right_code_clears_earlier_mistakes(self):
        for _ in range(4):
            self.call("open", body={"code": self.wrong()})
        self.assertEqual(self.open()[0], 200)
        self.assertEqual(self.store.fails(), 0)

    # --- who may ask -----------------------------------------------------------

    def test_other_repositories_branches_and_events_are_refused_without_counting(self):
        for change in (
            {"repository_id": "1"},
            {"repository_owner_id": "1"},
            {"ref": "refs/heads/other"},
            {"ref": "refs/pull/7/merge"},
            {"event_name": "push"},
            {"event_name": "pull_request"},
            {"aud": "sts.amazonaws.com"},
            {"iss": "https://example.com"},
            {"environment": None},
            {"environment": "staging"},
            {"run_id": None},
            {"run_attempt": "x"},
        ):
            for route in ("open", "credentials"):
                status, _ = self.call(route, self.claims(**change), {"code": self.code()})
                self.assertEqual(status, 403, (route, change))
        self.assertEqual((self.store.fails(), self.store.approvals, self.assumed), (0, {}, []))

    def test_only_the_trusted_commit(self):
        for change in ({"sha": OTHER, "workflow_sha": OTHER}, {"sha": OTHER}, {"workflow_sha": OTHER}, {"sha": None, "workflow_sha": None}):
            status, body = self.call("open", self.claims(**change), {"code": self.code()})
            self.assertEqual(status, 403, change)
            self.assertIn("deploy-gate.sh trust", body["message"])
        self.assertNotIn("last_step", self.store.users[ME])  # the code was not used up

    def test_a_token_with_only_sha_is_enough(self):
        self.assertEqual(self.open(workflow_sha=None)[0], 200)

    def test_nothing_is_trusted_at_first(self):
        self.store.trusted = None
        status, body = self.open()
        self.assertEqual(status, 403)
        self.assertIn("no commit is trusted", body["message"])

    def test_moving_the_trusted_commit_ends_running_approvals(self):
        self.open()
        self.store.trusted = OTHER
        self.assertEqual(self.call("credentials")[0], 403)
        self.assertEqual(self.call("credentials", self.claims(sha=OTHER, workflow_sha=OTHER))[0], 403)

    # --- one authenticator per person --------------------------------------------

    def test_someone_without_an_authenticator_is_refused_and_nothing_is_counted(self):
        for change in ({"actor": "stranger", "actor_id": STRANGER}, {"actor_id": None}, {"actor_id": "x"}, {"actor_id": ""}):
            for route in ("open", "credentials"):
                status, body = self.call(route, self.claims(**change), {"code": self.code()})
                self.assertEqual(status, 403, (route, change))
                self.assertIn("has no authenticator", body["message"])
        self.assertEqual(set(self.store.users), {ME, COLLEAGUE})  # no item was made for them
        self.assertEqual((self.store.fails(), self.store.fails(COLLEAGUE), self.store.approvals), (0, 0, {}))

    def test_a_code_only_opens_runs_its_owner_started(self):
        # my code on a run my colleague started: wrong, and it counts against them
        status, body = self.call("open", self.colleague(), {"code": self.code()})
        self.assertEqual(status, 403)
        self.assertIn("wrong code", body["message"])
        self.assertEqual((self.store.fails(COLLEAGUE), self.store.fails()), (1, 0))
        # their own code opens it, and my code is still unused
        self.assertEqual(self.call("open", self.colleague(), {"code": self.code(secret=OTHER_SECRET)})[0], 200)
        self.assertEqual(self.open(run_id="778")[0], 200)

    def test_each_person_has_their_environments(self):
        code = self.code(secret=OTHER_SECRET)
        status, body = self.call("open", self.colleague(environment="production"), {"code": code})
        self.assertEqual(status, 403)
        self.assertIn("may not start runs in the production environment", body["message"])
        self.assertEqual(self.store.fails(COLLEAGUE), 0)
        self.assertEqual(self.call("open", self.colleague(), {"code": code})[0], 200)  # deploy is theirs

    def test_removing_someone_ends_their_running_approval(self):
        self.assertEqual(self.call("open", self.colleague(), {"code": self.code(secret=OTHER_SECRET)})[0], 200)
        self.assertEqual(self.call("credentials", self.colleague())[0], 200)
        del self.store.users[COLLEAGUE]
        self.assertEqual(self.call("credentials", self.colleague())[0], 403)

    def test_taking_an_environment_away_ends_the_approval_for_it(self):
        self.open(environment="production")
        self.store.users[ME]["environments"] = ["deploy"]
        self.assertEqual(self.call("credentials", self.claims(environment="production"))[0], 403)

    def test_an_approval_belongs_to_who_started_the_run(self):
        self.open()
        # the same run cannot come from someone else; if a token said so, it gets nothing
        self.assertEqual(self.call("credentials", self.colleague())[0], 403)

    def test_someone_removed_during_a_request_is_not_brought_back(self):
        def read_and_remove(actor_id):
            secret = self.secrets.get(actor_id)
            del self.store.users[actor_id]
            return secret

        self.gate.read_secret = read_and_remove
        for code in (self.wrong(), self.code()):
            self.store.users[ME] = {"login": "someone", "environments": ["deploy"]}
            status, _ = self.call("open", body={"code": code})
            self.assertEqual(status, 403)
            self.assertNotIn(ME, self.store.users)
        self.assertEqual(self.store.approvals, {})

    def test_an_authenticator_that_was_never_stored(self):
        del self.secrets[ME]
        status, body = self.open()
        self.assertEqual(status, 403)
        self.assertIn("never stored", body["message"])
        self.assertEqual(self.store.fails(), 0)

    # --- plumbing --------------------------------------------------------------

    def test_requests_that_did_not_pass_the_authorizer(self):
        response = handler.handle(self.gate, {"routeKey": "POST /open", "requestContext": {}, "body": "{}"})
        self.assertEqual(response["statusCode"], 401)
        response = handler.handle(self.gate, {"routeKey": "GET /open", "requestContext": {}})
        self.assertEqual(response["statusCode"], 404)

    def test_a_body_that_is_not_an_object(self):
        for body in ("[]", "not json", '"x"'):
            event = {
                "routeKey": "POST /open",
                "requestContext": {"authorizer": {"jwt": {"claims": self.claims()}}},
                "body": body,
            }
            self.assertEqual(handler.handle(self.gate, event)["statusCode"], 400, body)

    def test_the_log_never_holds_a_code_or_a_credential(self):
        self.call("open", body={"code": self.wrong()})
        code = self.code()
        self.open()
        self.call("credentials")
        log = "\n".join(self.events)
        self.assertEqual([json.loads(e)["event"] for e in self.events], ["refused", "opened", "credentials"])
        self.assertEqual(json.loads(self.events[0])["reason"], "wrong code")
        for secret in (code, self.wrong(), "ASIA", SECRET):
            self.assertNotIn(secret, log)

    def logged(self):
        return [json.loads(e) for e in self.events]

    def test_every_refusal_is_logged_with_who_asked(self):
        # a run of another repository
        self.call("open", self.claims(repository_id="1", repository="evil/fork", actor="mallory"), {"code": self.code()})
        # a run of this repository at a commit nobody approved
        self.call("open", self.claims(sha=OTHER, workflow_sha=OTHER), {"code": self.code()})
        # credentials without an approval
        self.call("credentials")
        first, second, third = self.logged()
        self.assertEqual((first["event"], first["repository"], first["actor"], first["status"]), ("refused", "evil/fork", "mallory", 403))
        self.assertEqual(first["actor_id"], ME)
        self.assertIn("repository_id", first["reason"])
        self.assertEqual((second["sha"], second["workflow_sha"], second["route"]), (OTHER, OTHER, "POST /open"))
        self.assertIn("trusted", second["reason"])
        self.assertEqual((third["route"], third["run_id"], third["run_attempt"]), ("POST /credentials", "777", "1"))
        self.assertIn("no approval", third["reason"])
        self.assertNotIn(self.code(), "\n".join(self.events))

    def test_expired_and_locked_have_their_own_events(self):
        self.call("open", body={"code": self.code(-10)})
        for _ in range(5):
            self.call("open", body={"code": self.wrong()})
        self.open()
        events = [(e["event"], e.get("failures")) for e in self.logged()]
        self.assertEqual(events, [("expired", None)] + [("refused", n) for n in range(1, 6)] + [("locked", None)])
        self.assertEqual(self.logged()[-1]["status"], 423)

    def test_long_claims_are_cut_in_the_log(self):
        self.call("open", self.claims(repository_id="1", ref="refs/heads/" + "x" * 5000))
        self.assertLessEqual(len(self.logged()[0]["ref"]), 200)


if __name__ == "__main__":
    unittest.main()
