"""Time-based one-time passwords (RFC 6238) as Google Authenticator makes them:
HMAC-SHA1, 6 digits, a new code every 30 seconds. Standard library only, shared by
the gate (handler.py) and scripts/deploy-gate.sh."""
import base64
import hashlib
import hmac
import struct

PERIOD = 30
DIGITS = 6


def code_at(secret_b32, step):
    """The code of one 30-second step."""
    text = "".join(secret_b32.split()).upper()
    key = base64.b32decode(text + "=" * (-len(text) % 8))
    mac = hmac.new(key, struct.pack(">Q", step), hashlib.sha1).digest()
    offset = mac[-1] & 0x0F
    number = struct.unpack(">I", mac[offset : offset + 4])[0] & 0x7FFFFFFF
    return str(number % 10**DIGITS).zfill(DIGITS)


def matching_step(secret_b32, code, now, past=2, future=1):
    """The step whose code this is, or None. Accepts the current step, `past`
    earlier ones (a workflow run takes a while to start) and `future` later ones
    (clock drift). Every candidate is compared, so timing does not show which."""
    current = int(now) // PERIOD
    found = None
    for step in range(current - past, current + future + 1):
        if hmac.compare_digest(code_at(secret_b32, step), str(code)):
            found = step
    return found
