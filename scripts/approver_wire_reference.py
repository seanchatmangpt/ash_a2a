#!/usr/bin/env python3
"""Reference client for the authority service's "approve" wire op.

An independent (third) implementation of what `sa2a-approver approve` (Swift,
sa2a-approver/Sources/SA2AApproverCore/WireApproval.swift) and `AshA2A.C2.ApproveClient`
(Elixir) put on the wire. Stdlib plus `cryptography` (pip) only.

Modes:
  build     read one JSON request on stdin, print the pre-signature bytes, the envelope and the
            request body (used by test/ash_a2a/c2/approve_wire_crosscheck_test.exs)
  selftest  start the REAL AuthorityService.Listener (authority_service/, MIX_ENV=test, via
            sa2a-approver/scripts/authority_listener_harness.exs) and drive it over a unix
            socket: acceptance and each refusal; with --swift BIN also the Swift CLI.

Run:  python3 scripts/approver_wire_reference.py selftest [--swift PATH/TO/sa2a-approver]
"""
import base64
import hashlib
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature, encode_dss_signature

DOMAIN = b"SA2A-C2-APPROVAL-v1\x00"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551


def b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def jcs(obj):
    """RFC 8785 for the value space used here: ASCII keys, strings, integers, objects."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def spki_of(pub):
    return pub.public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)


def x963_of(pub):
    return pub.public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)


def kid_of(pub):
    return b64u(hashlib.sha256(spki_of(pub)).digest()[:16])


def digest_of(data):
    return "sha256:" + hashlib.sha256(data).hexdigest()


def signed_bytes(fields):
    """`"SA2A-C2-APPROVAL-v1" || 0x00 || JCS({12 fields})`."""
    return DOMAIN + jcs(fields)


def sign_der(priv, message):
    """ECDSA P-256/SHA-256, X9.62 DER, low-s normalised (the strict parser accepts both)."""
    r, s = decode_dss_signature(priv.sign(message, ec.ECDSA(hashes.SHA256())))
    if s > N // 2:
        s = N - s
    return encode_dss_signature(r, s)


def envelope(fields, signature_der, message):
    return {
        "v": fields["v"], "alg": fields["alg"], "kid": fields["kid"], "profile": "classical",
        "signed_bytes_digest": digest_of(message), "signature": b64u(signature_der),
        "nonce": fields["nonce"], "not_before": fields["not_before"], "expires": fields["expires"],
        "audience": fields["audience"],
    }


def request_body(approver, fields, signature_der, message):
    return jcs({
        "op": "approve", "approver": approver, "effect_digest": fields["effect_digest"],
        "generation": fields["generation"],
        "approval": {"envelope": envelope(fields, signature_der, message), "message": b64u(message)},
    })


def frame(body):
    return struct.pack(">I", len(body)) + body


def _read(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise RuntimeError("short read")
        buf += chunk
    return buf


def call_uds(path, body, timeout=5):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(timeout)
        s.connect(path)
        s.sendall(frame(body))
        (n,) = struct.unpack(">I", _read(s, 4))
        return json.loads(_read(s, n))


def fields_for(kid, effect_digest, *, generation=9, nonce=None, now=None, audience="authority:test", **over):
    now = int(time.time()) if now is None else now
    f = {
        "v": 1, "alg": "ES256", "kid": kid, "effect_digest": effect_digest, "principal": "agent:alice",
        "policy_epoch": 3, "revocation_epoch": 4, "generation": generation,
        "nonce": nonce or b64u(os.urandom(12)), "not_before": now - 10, "expires": now + 200,
        "audience": audience,
    }
    f.update(over)
    return f


# ---------------------------------------------------------------- build mode

def cmd_build():
    """stdin: {fields, approver, signature_b64u?, private_key_pem?}. A given signature is used
    as is (so Elixir and Python can sign nothing and still compare bytes); otherwise it is made
    with private_key_pem."""
    req = json.load(sys.stdin)
    fields = req["fields"]
    msg = signed_bytes(fields)
    if "signature_b64u" in req:
        sig = base64.urlsafe_b64decode(req["signature_b64u"] + "=" * (-len(req["signature_b64u"]) % 4))
    else:
        priv = serialization.load_pem_private_key(req["private_key_pem"].encode(), None)
        sig = sign_der(priv, msg)
    body = request_body(req["approver"], fields, sig, msg)
    print(json.dumps({
        "message_b64u": b64u(msg), "envelope_b64u": b64u(jcs(envelope(fields, sig, msg))),
        "signature_b64u": b64u(sig), "body_b64u": b64u(body),
    }))


# ------------------------------------------------------------- selftest mode

class Results:
    def __init__(self):
        self.ok = 0
        self.failed = []

    def check(self, name, got, want):
        if got == want:
            self.ok += 1
            print(f"ok   {name}")
        else:
            self.failed.append(name)
            print(f"FAIL {name}\n     got  {got!r}\n     want {want!r}")


def refusal(reply):
    return "ok" if reply.get("ok") is True else reply.get("refusal")


def start_listener(work, approvers):
    cfg = os.path.join(work, "config.json")
    with open(cfg, "w") as fh:
        json.dump({"dir": work, "approvers": approvers, "tls": None}, fh)
    env = dict(os.environ, MIX_ENV="test", APPROVER_HARNESS_CONFIG=cfg)
    log = open(os.path.join(work, "listener.log"), "w")
    proc = subprocess.Popen(
        ["mix", "run", "--no-halt", os.path.join(ROOT, "sa2a-approver/scripts/authority_listener_harness.exs")],
        cwd=os.path.join(ROOT, "authority_service"), env=env, stdout=log, stderr=subprocess.STDOUT)
    ready = os.path.join(work, "ready.json")
    for _ in range(600):
        if os.path.exists(ready):
            with open(ready) as fh:
                return proc, json.load(fh)
        if proc.poll() is not None:
            break
        time.sleep(0.5)
    proc.terminate()
    raise SystemExit("listener did not start; see " + os.path.join(work, "listener.log"))


def swift_capture(swift, work, key_file, message_file, effect_file, approver):
    """Run `sa2a-approver approve` against a one-shot capture socket; return (request body, signature)."""
    path = os.path.join(work, "cap.sock")
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(path)
    srv.listen(1)
    env = dict(os.environ, SA2A_APPROVER_DEV="1")
    proc = subprocess.Popen(
        [swift, "approve", "--key", "software", "--key-file", key_file, "--message", message_file,
         "--effect", effect_file, "--approver", approver, "--socket", path],
        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    srv.settimeout(10)
    conn, _ = srv.accept()
    (n,) = struct.unpack(">I", _read(conn, 4))
    body = _read(conn, n)
    reply = b'{"ok":true}'
    conn.sendall(frame(reply))
    conn.close()
    proc.communicate(timeout=10)
    srv.close()
    return body, proc.returncode


def selftest(swift):
    res = Results()
    effect = jcs({"capability": "deploy.release", "inputs": {"env": "prod", "replicas": 3}, "target": "svc/payments"})
    digest = digest_of(effect)
    keys = {n: ec.generate_private_key(ec.SECP256R1()) for n in ("alice", "carol", "mallory")}
    approvers = {n: x963_of(k.public_key()).hex() for n, k in keys.items() if n != "mallory"}
    work = tempfile.mkdtemp(prefix="approver-wire-")
    swift_key = os.path.join(work, "swift.key")
    if swift:
        env = dict(os.environ, SA2A_APPROVER_DEV="1")
        spki_file = os.path.join(work, "bob.spki")
        subprocess.run([swift, "pubkey", "--key", "software", "--key-file", swift_key, "--out", spki_file],
                       check=True, env=env, capture_output=True)
        spki = open(spki_file, "rb").read()
        approvers["bob"] = spki[-65:].hex()
        swift_kid = b64u(hashlib.sha256(spki).digest()[:16])
    proc, ready = start_listener(work, approvers)
    sock = ready["sock"]
    aud = ready["audience"]
    try:
        def sub(approver, fields, signer, *, effect_digest=None, generation=None, tamper=False):
            msg = signed_bytes(fields)
            sig = sign_der(keys[signer], msg)
            if tamper:
                sig = sig[:-1] + bytes([sig[-1] ^ 1])
            f = dict(fields)
            body = json.loads(request_body(approver, f, sig, msg))
            if effect_digest is not None:
                body["effect_digest"] = effect_digest
            if generation is not None:
                body["generation"] = generation
            return call_uds(sock, jcs(body)), body

        kid = {n: kid_of(k.public_key()) for n, k in keys.items()}
        nonce_a = b64u(os.urandom(12))
        fa = fields_for(kid["alice"], digest, nonce=nonce_a, audience=aud)
        reply, body_a = sub("alice", fa, "alice")
        res.check("accepts a valid approval", refusal(reply), "ok")
        res.check("duplicate: same slot, same approval", refusal(call_uds(sock, jcs(body_a))), "duplicate_approval")
        reply, _ = sub("alice", fields_for(kid["alice"], digest, audience=aud), "alice")
        res.check("full slot: first-wins, a fresh approval cannot overwrite", refusal(reply), "duplicate_approval")
        reply, _ = sub("alice", fields_for(kid["alice"], digest, generation=10, nonce=nonce_a, audience=aud), "alice")
        res.check("duplicate nonce: (kid, nonce) reused on a new slot", refusal(reply), "duplicate_approval")

        reply, _ = sub("carol", fields_for(kid["alice"], digest, audience=aud), "alice")
        res.check("wrong signer: alice's approval under carol's slot", refusal(reply), "approval_invalid")
        reply, _ = sub("alice", fields_for(kid["mallory"], digest, audience=aud), "mallory")
        res.check("unregistered key", refusal(reply), "approval_invalid")
        reply, _ = sub("carol", fields_for(kid["carol"], digest, audience=aud), "carol", tamper=True)
        res.check("tampered signature", refusal(reply), "approval_invalid")
        reply, _ = sub("carol", fields_for(kid["carol"], digest, audience=aud), "carol", effect_digest="sha256:" + "0" * 64)
        res.check("slot digest differs from the signed effect_digest", refusal(reply), "approval_invalid")
        reply, _ = sub("carol", fields_for(kid["carol"], digest, audience=aud), "carol", generation=10)
        res.check("slot generation differs from the signed generation", refusal(reply), "approval_invalid")
        reply, _ = sub("carol", fields_for(kid["carol"], digest, audience="actuator:other"), "carol")
        res.check("wrong audience", refusal(reply), "approval_invalid")
        now = int(time.time())
        reply, _ = sub("carol", fields_for(kid["carol"], digest, audience=aud, not_before=now - 400, expires=now - 100), "carol")
        res.check("expired approval", refusal(reply), "approval_invalid")

        good = lambda: json.loads(request_body(
            "carol", (lambda f: f)(fields_for(kid["carol"], digest, audience=aud)),
            b"\x30\x06\x02\x01\x01\x02\x01\x01", signed_bytes(fields_for(kid["carol"], digest, audience=aud))))
        b = good(); b["approval"]["envelope"] = "x"
        res.check("malformed: envelope is not an object", refusal(call_uds(sock, jcs(b))), "malformed_approval")
        b = good(); del b["approval"]["envelope"]["nonce"]
        res.check("malformed: envelope missing a field", refusal(call_uds(sock, jcs(b))), "malformed_approval")
        b = good(); b["approval"]["envelope"]["extra"] = 1
        res.check("malformed: envelope with an extra field", refusal(call_uds(sock, jcs(b))), "malformed_approval")
        b = good(); b["approval"]["message"] = "!!not-base64url!!"
        res.check("malformed: message is not base64url", refusal(call_uds(sock, jcs(b))), "malformed_approval")
        b = good(); b["approval"]["message"] = b64u(b"x" * 8193)
        res.check("malformed: message over 8192 bytes", refusal(call_uds(sock, jcs(b))), "malformed_approval")
        b = good(); b["approval"]["envelope"]["signature"] = b64u(b"x") + "="
        res.check("malformed: padded base64url signature", refusal(call_uds(sock, jcs(b))), "malformed_approval")
        b = good(); del b["approval"]
        res.check("malformed request: no approval", refusal(call_uds(sock, jcs(b))), "malformed_request")
        res.check("unknown op", refusal(call_uds(sock, jcs({"op": "nope"}))), "unknown_op")

        if swift:
            msg_f, eff_f = os.path.join(work, "m.bin"), os.path.join(work, "e.json")
            open(eff_f, "wb").write(effect)
            now = int(time.time())
            fb = fields_for(swift_kid, digest, audience=aud, generation=21, not_before=now - 10, expires=now + 200)
            open(msg_f, "wb").write(signed_bytes(fb))
            env = dict(os.environ, SA2A_APPROVER_DEV="1")
            args = [swift, "approve", "--key", "software", "--key-file", swift_key, "--message", msg_f,
                    "--effect", eff_f, "--approver", "bob", "--socket", sock]
            r = subprocess.run(args, env=env, capture_output=True, text=True)
            res.check("swift: approve accepted by the real listener", (r.returncode, r.stdout.strip().splitlines()[-1:]), (0, ["submitted"]))
            r = subprocess.run(args, env=env, capture_output=True, text=True)
            res.check("swift: resubmit refused as duplicate_approval",
                      (r.returncode, "duplicate_approval" in r.stderr), (2, True))
            fc = fields_for(swift_kid, digest, audience=aud, generation=22, not_before=now - 10, expires=now + 200)
            open(msg_f, "wb").write(signed_bytes(fc))
            body, rc = swift_capture(swift, work, swift_key, msg_f, eff_f, "bob")
            parsed = json.loads(body)
            sig = base64.urlsafe_b64decode(parsed["approval"]["envelope"]["signature"] + "==")
            pub = serialization.load_der_public_key(open(os.path.join(work, "bob.spki"), "rb").read())
            try:
                pub.verify(sig, signed_bytes(fc), ec.ECDSA(hashes.SHA256()))
                verified = True
            except Exception:
                verified = False
            res.check("swift: signature verifies in Python (cryptography)", verified, True)
            res.check("swift: request body is byte-identical to the Python builder",
                      body, request_body("bob", fc, sig, signed_bytes(fc)))

        # mailbox_full: the mailbox holds at most 1024 slots (fill with carol, valid approvals).
        verdict, sent = None, 0
        for g in range(1000, 2200):
            reply, _ = sub("carol", fields_for(kid["carol"], digest, generation=g, audience=aud), "carol")
            sent += 1
            verdict = refusal(reply)
            if verdict != "ok":
                break
        res.check("mailbox full: refused after the 1024-entry cap", verdict, "mailbox_full")
        print(f"     (carol filled {sent - 1} slots; alice/bob held others)")
    finally:
        proc.terminate()
        try:
            proc.wait(10)
        except subprocess.TimeoutExpired:
            proc.kill()
    print(f"\n{res.ok} passed, {len(res.failed)} failed" + (": " + ", ".join(res.failed) if res.failed else ""))
    sys.exit(1 if res.failed else 0)


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode == "build":
        cmd_build()
    elif mode == "selftest":
        selftest(sys.argv[sys.argv.index("--swift") + 1] if "--swift" in sys.argv else None)
    else:
        sys.exit(__doc__)
