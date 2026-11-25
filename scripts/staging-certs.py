#!/usr/bin/env python3
"""Client certificates for the staging load balancer (environments/staging/alb.tf).

Only people holding a certificate signed by the staging CA get past port 443 of
staging. This script is that CA: it creates it, issues and revokes certificates,
and publishes the revocation list to the load balancer's trust store.

    staging-certs.py init                        create the CA, once, before the first apply
    staging-certs.py issue NAME [--days 90]      a key and certificate for NAME, as NAME.p12
                    [--csr FILE] [--out DIR]     (with --csr: sign their request instead,
                                                  their key never leaves their machine)
    staging-certs.py revoke NAME|0xSERIAL        stop a certificate working (lost laptop,
                                                  engagement over), within a minute or two
    staging-certs.py list                        every certificate issued, valid or revoked
    staging-certs.py crl                         publish the revocation list again

Runs with the staging account's admin credentials (AWS_PROFILE) and refuses any
other account: STAGING_ACCOUNT_ID must be set and match. Needs openssl and the
AWS CLI.

Where things are:
    CA private key, the issued-certificate index   Secrets Manager postiz/staging-admin/client-ca
                                                   (outside postiz/staging/, so no task can read it)
    CA certificate                                 environments/staging/client-ca.pem (commit it)
    revocation lists                               s3://postiz-staging-trust-store-<account>/crl/

NAME is who the certificate is for (a-z, 0-9, dots and dashes): "dana",
"pentester-1". It becomes the certificate's CN, which the load balancer's
connection log records for every connection.

The .p12 is protected by a password the script prints once: send the file and
the password by different channels. Certificates last 90 days unless --days says
otherwise; issue a new one before that.
"""

import argparse
import datetime
import json
import os
import re
import secrets
import shutil
import string
import subprocess
import sys
import tempfile

SECRET_ID = "postiz/staging-admin/client-ca"
NAME = "postiz-staging"
REGION = os.environ.get("AWS_REGION", "us-east-2")
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CA_FILE = os.path.join(REPO, "environments", "staging", "client-ca.pem")
CA_DAYS = 1825
CA_CN = "Postiz staging client CA"
CRL_DAYS = 3650

OPENSSL_CNF = """\
[ ca ]
default_ca = staging

[ staging ]
dir           = {dir}
database      = {dir}/index.txt
crlnumber     = {dir}/crlnumber
certificate   = {dir}/ca.pem
private_key   = {dir}/ca.key
default_md    = sha256
default_crl_days = {crl_days}

[ req ]
distinguished_name = ca_dn
prompt             = no

# the CA's own name (init); LibreSSL ignores -subj when prompt = no
[ ca_dn ]
O  = Postiz
CN = {ca_cn}

[ ca_ext ]
basicConstraints       = critical, CA:TRUE, pathlen:0
keyUsage               = critical, keyCertSign, cRLSign
subjectKeyIdentifier   = hash

[ client_ext ]
basicConstraints       = critical, CA:FALSE
keyUsage               = critical, digitalSignature, keyEncipherment
extendedKeyUsage       = clientAuth
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid
"""


def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def run(args, **kw):
    return subprocess.run(args, check=True, text=True, capture_output=True, **kw).stdout


def aws(*args, quiet_errors=False):
    cmd = ["aws", "--region", REGION, "--output", "json", *args]
    p = subprocess.run(cmd, text=True, capture_output=True)
    if p.returncode != 0:
        if quiet_errors:
            return None
        die(f"aws {' '.join(args[:2])} failed: {p.stderr.strip()}")
    return json.loads(p.stdout) if p.stdout.strip() else {}


def check_account():
    want = os.environ.get("STAGING_ACCOUNT_ID", "")
    if not re.fullmatch(r"\d{12}", want):
        die("set STAGING_ACCOUNT_ID to the staging account's id")
    have = aws("sts", "get-caller-identity")["Account"]
    if have != want:
        die(f"these credentials are for account {have}, not staging ({want}): check AWS_PROFILE")
    return have


def current_version():
    stages = aws("secretsmanager", "describe-secret", "--secret-id", SECRET_ID, "--query", "VersionIdsToStages")
    return next((v for v, labels in (stages or {}).items() if "AWSCURRENT" in labels), None)


def load_state():
    out = aws("secretsmanager", "get-secret-value", "--secret-id", SECRET_ID, "--query", "{s:SecretString,v:VersionId}", quiet_errors=True)
    if out is None:
        die(f"no CA yet ({SECRET_ID}): run init first")
    state = json.loads(out["s"])
    # what this run started from: save_state refuses if someone saved since
    state["_base_version"] = out["v"]
    return state


def secret_file(state):
    """The state in a 0600 file, so the CA key never shows on a command line."""
    fd, path = tempfile.mkstemp(prefix="staging-ca-state-")
    with os.fdopen(fd, "w") as f:
        f.write(json.dumps(state))
    return path


def save_state(state):
    """Write the CA state, unless another run saved since this one loaded it: two
    runs at once must neither hand out one serial twice nor lose a revocation.
    (Secrets Manager has no conditional write, so a narrow race remains: one
    person at a time.)"""
    base = state.pop("_base_version", None)
    if base is not None and current_version() != base:
        die("the CA changed while this ran (someone else issued or revoked): nothing saved, run it again")
    path = secret_file(state)
    try:
        new = aws("secretsmanager", "put-secret-value", "--secret-id", SECRET_ID, "--secret-string", f"file://{path}")
    finally:
        os.remove(path)
    state["_base_version"] = new.get("VersionId")


class Workdir:
    """The CA's files in a private temporary directory, removed on exit."""

    def __init__(self, state=None):
        self.dir = tempfile.mkdtemp(prefix="staging-ca-")
        os.chmod(self.dir, 0o700)
        self.cnf = self.path("openssl.cnf")
        self.write("openssl.cnf", OPENSSL_CNF.format(dir=self.dir, crl_days=CRL_DAYS, ca_cn=CA_CN))
        if state:
            self.write("ca.key", state["ca_key"])
            self.write("ca.pem", state["ca_cert"])
            self.write("index.txt", state["index"])
            self.write("index.txt.attr", "unique_subject = no\n")
            self.write("crlnumber", "%04X\n" % state["crl_number"])

    def path(self, name):
        return os.path.join(self.dir, name)

    def write(self, name, content):
        fd = os.open(self.path(name), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(content)

    def read(self, name):
        with open(self.path(name)) as f:
            return f.read()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        shutil.rmtree(self.dir, ignore_errors=True)


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc)


def asn1_time(dt):
    return dt.strftime("%y%m%d%H%M%SZ")


def cert_field(path, flag):
    return run(["openssl", "x509", "-in", path, "-noout", flag]).strip().split("=", 1)[1]


def index_entries(state):
    for line in state["index"].splitlines():
        parts = line.split("\t")
        if len(parts) == 6:
            yield parts


def cn_of(subject):
    m = re.search(r"CN\s*=\s*([^,/]+)", subject)
    return m.group(1).strip() if m else subject


# --- commands ------------------------------------------------------------------------


def cmd_init(_args):
    check_account()
    if aws("secretsmanager", "describe-secret", "--secret-id", SECRET_ID, quiet_errors=True) is not None:
        die(f"{SECRET_ID} already exists: the CA is made once. A new CA would invalidate every certificate.")
    with Workdir() as w:
        run(["openssl", "genrsa", "-out", w.path("ca.key"), "3072"])
        os.chmod(w.path("ca.key"), 0o600)
        run([
            "openssl", "req", "-x509", "-new", "-key", w.path("ca.key"), "-sha256", "-days", str(CA_DAYS),
            "-config", w.cnf, "-extensions", "ca_ext", "-out", w.path("ca.pem"),
        ])
        state = {
            "ca_key": w.read("ca.key"),
            "ca_cert": w.read("ca.pem"),
            "index": "",
            "next_serial": 4096,
            "crl_number": 4096,
        }
        path = secret_file(state)
        try:
            aws(
                "secretsmanager", "create-secret", "--name", SECRET_ID,
                "--description", "Client certificate authority of the staging load balancer (scripts/staging-certs.py)",
                "--secret-string", f"file://{path}",
            )
        finally:
            os.remove(path)
        # the trust store wants plain PEM: no blank lines, comments only with #
        with open(CA_FILE, "w") as f:
            f.write(state["ca_cert"].strip() + "\n")
    print(f"CA created. Its key is in {SECRET_ID}; its certificate is {os.path.relpath(CA_FILE, REPO)}:")
    print("commit that file, then apply environments/staging.")


def cmd_issue(args):
    check_account()
    if not re.fullmatch(r"[a-z0-9][a-z0-9.-]{0,62}", args.name):
        die("NAME: lowercase letters, digits, dots and dashes")
    if not 1 <= args.days <= 397:
        die("--days: 1 to 397")
    state = load_state()
    out_dir = os.path.abspath(args.out)
    serial = state["next_serial"]
    with Workdir(state) as w:
        if args.csr:
            shutil.copy(args.csr, w.path("req.csr"))
            os.chmod(w.path("req.csr"), 0o600)
            requested = run(["openssl", "req", "-in", w.path("req.csr"), "-noout", "-subject"])
            if cn_of(requested) != args.name:
                die(f"the request's CN is {cn_of(requested)!r}, not {args.name!r}: ask for one made with -subj /CN={args.name}")
            subject = f"/CN={args.name}"
        else:
            subject = f"/O=Postiz staging/CN={args.name}"
            run(["openssl", "genrsa", "-out", w.path("client.key"), "2048"])
            run(["openssl", "req", "-new", "-key", w.path("client.key"), "-subj", subject, "-out", w.path("req.csr")])
        run([
            "openssl", "x509", "-req", "-in", w.path("req.csr"), "-CA", w.path("ca.pem"), "-CAkey", w.path("ca.key"),
            "-set_serial", str(serial), "-days", str(args.days), "-sha256",
            "-extfile", w.cnf, "-extensions", "client_ext", "-out", w.path("client.pem"),
        ])
        not_after = datetime.datetime.strptime(cert_field(w.path("client.pem"), "-enddate"), "%b %d %H:%M:%S %Y %Z")
        not_after = not_after.replace(tzinfo=datetime.timezone.utc)
        serial_hex = "%X" % serial
        if len(serial_hex) % 2:
            serial_hex = "0" + serial_hex
        state["index"] += "\t".join(["V", asn1_time(not_after), "", serial_hex, "unknown", subject]) + "\n"
        state["next_serial"] = serial + 1
        save_state(state)

        os.makedirs(out_dir, exist_ok=True)
        if args.csr:
            dest = os.path.join(out_dir, f"{args.name}.pem")
            shutil.copy(w.path("client.pem"), dest)
            print(f"signed: {dest} (serial {serial_hex}, valid until {not_after:%Y-%m-%d})")
            print("send it back with environments/staging/client-ca.pem; their key stayed with them.")
            return
        password = "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(24))
        dest = os.path.join(out_dir, f"{args.name}.p12")
        # 3DES/SHA1 protection: what macOS Keychain, Windows and Java (Burp) all import
        run([
            "openssl", "pkcs12", "-export", "-inkey", w.path("client.key"), "-in", w.path("client.pem"),
            "-certfile", w.path("ca.pem"), "-name", f"{args.name} (Postiz staging)",
            "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1",
            "-passout", "env:P12_PASSWORD", "-out", dest,
        ], env={**os.environ, "P12_PASSWORD": password})
        os.chmod(dest, 0o600)
    print(f"issued: {dest} (serial {serial_hex}, valid until {not_after:%Y-%m-%d})")
    print(f"password: {password}")
    print("Send the file and the password by different channels. Install: double-click it (macOS,")
    print("Windows), or in Burp: Settings > Network > TLS > Client TLS certificates, host *.getpostiz.com.")
    print("curl: (umask 077; openssl pkcs12 -in FILE -nodes -out me.pem); curl --cert me.pem https://api.getpostiz.com/")


def cmd_revoke(args):
    check_account()
    state = load_state()
    m = re.fullmatch(r"0[xX]0*([0-9a-fA-F]+)", args.name_or_serial)
    target = m.group(1).upper() if m else None
    now = asn1_time(utc_now())
    lines, hits = [], 0
    for parts in index_entries(state):
        status, exp, rev, serial, fname, subject = parts
        match = (target is not None and serial.lstrip("0") == target) or cn_of(subject) == args.name_or_serial
        if match and status == "V":
            parts = ["R", exp, now, serial, fname, subject]
            hits += 1
            print(f"revoking {cn_of(subject)} serial {serial}")
        lines.append("\t".join(parts))
    if not hits:
        die(f"no valid certificate for {args.name_or_serial!r} (see: list)")
    state["index"] = "\n".join(lines) + "\n"
    publish_crl(state)


def cmd_crl(_args):
    check_account()
    publish_crl(load_state())


def publish_crl(state):
    account = os.environ["STAGING_ACCOUNT_ID"]
    bucket = f"{NAME}-trust-store-{account}"
    stores = aws("elbv2", "describe-trust-stores", "--names", f"{NAME}-clients", quiet_errors=True)
    if not stores or not stores.get("TrustStores"):
        die(f"no trust store {NAME}-clients: apply environments/staging first (client_certificates_required = true)")
    store_arn = stores["TrustStores"][0]["TrustStoreArn"]
    with Workdir(state) as w:
        key = f"crl/crl-{state['crl_number']}.pem"
        run(["openssl", "ca", "-gencrl", "-config", w.cnf, "-out", w.path("crl.pem")])
        state["crl_number"] = int(w.read("crlnumber").strip(), 16)
        aws("s3api", "put-object", "--bucket", bucket, "--key", key, "--body", w.path("crl.pem"), "--content-type", "application/x-pem-file")
    # the state first: a revocation must never be lost, even if the trust store update fails
    save_state(state)
    old = aws("elbv2", "describe-trust-store-revocations", "--trust-store-arn", store_arn).get("TrustStoreRevocations", [])
    aws(
        "elbv2", "add-trust-store-revocations", "--trust-store-arn", store_arn,
        "--revocation-contents", f"S3Bucket={bucket},S3Key={key},RevocationType=CRL",
    )
    ids = [str(r["RevocationId"]) for r in old]
    if ids:
        aws("elbv2", "remove-trust-store-revocations", "--trust-store-arn", store_arn, "--revocation-ids", *ids)
    print(f"revocation list s3://{bucket}/{key} is in the trust store (replacing {len(ids)} older)")


def cmd_list(_args):
    check_account()
    state = load_state()
    rows = list(index_entries(state))
    if not rows:
        print("no certificates issued yet")
        return
    now = asn1_time(utc_now())
    for status, exp, rev, serial, _, subject in rows:
        state_word = {"V": "valid", "R": "revoked"}.get(status, status)
        if status == "V" and exp < now:
            state_word = "expired"
        expires = datetime.datetime.strptime(exp, "%y%m%d%H%M%SZ").strftime("%Y-%m-%d")
        print(f"{state_word:8} {cn_of(subject):30} serial {serial:8} until {expires}")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="command", required=True)
    sub.add_parser("init").set_defaults(func=cmd_init)
    i = sub.add_parser("issue")
    i.add_argument("name")
    i.add_argument("--days", type=int, default=90)
    i.add_argument("--csr")
    i.add_argument("--out", default=".")
    i.set_defaults(func=cmd_issue)
    r = sub.add_parser("revoke")
    r.add_argument("name_or_serial")
    r.set_defaults(func=cmd_revoke)
    sub.add_parser("list").set_defaults(func=cmd_list)
    sub.add_parser("crl").set_defaults(func=cmd_crl)
    args = p.parse_args()
    for tool in ("openssl", "aws"):
        if not shutil.which(tool):
            die(f"{tool} not found")
    args.func(args)


if __name__ == "__main__":
    main()
