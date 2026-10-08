"""Lane DY4 extension courts: AUTH-* / VER-CLIENT / VER-SERVER-001 / BIND-EQUIV.

This module is NOT part of the official a2a-tck suite at pin
263b9cfaf16a554bdfb166a7ba5b67716e946349. It is a local extension court
module written for the ash_a2a lane DY4 (tck-vuln-hardening) that uses the
TCK's own machinery (registry, transport clients, compatibility collector)
to exercise requirement IDs the official suite at this pin structurally
skips: every one of these requirements has `operation: None` and is
excluded from the parametrized runner (tests/compatibility/core_operations/
test_requirements.py `_parametrize_requirements` drops requirements without
an operation), and no dedicated test module covers them.

Canonical copy: /Users/sac/ash_a2a/priv/tck/test_dy4_auth_lanes.py
Copied at run time to <tck>/tests/compatibility/test_dy4_auth_lanes.py so it
inherits the compatibility_collector fixture; results are recorded into the
same compatibility.json the official suite produces.

SUT: the DY4 auth/TLS SUT variant (`tck_sut_auth.exs`), which:
  * requires a scoped HS256 JWT bearer token on every A2A request
    (AshA2A.Protocol.Plug.Auth, RFC 7235 challenges);
  * declares the scheme in its agent card (securitySchemes/securityRequirements);
  * serves a real TLS listener with an openssl CA -> localhost/127.0.0.1
    server cert (validated by the TCK's own httpx via SSL_CERT_FILE);
  * parks `tck-auth-required-*` messages in TASK_STATE_AUTH_REQUIRED and
    resumes them on follow-up (spec §7.6.1);
  * exposes `GET /__tck_observed` reporting the A2A-Version headers the TCK
    client actually presented (VER-CLIENT evidence, observed server-side).

Environment:
  TCK_AUTH_SUT_URL (default http://localhost:9998)
  TCK_AUTH_TLS_URL (default https://localhost:9443)
  SSL_CERT_FILE must point at the SUT's CA bundle for the TLS courts
  (/tmp/tck_dy4_tls/ca.pem) — httpx uses the default SSL context.

Honest blockers (left NOT TESTED, not recorded as skips):
  AUTH-INTASK-004 — requires observing an out-of-band credential channel;
    the parked/resume flow covers the task-side contract but nobody observes
    the out-of-band leg end to end.
  AUTH-INTASK-005 — SHOULD: maintaining response streams across auth_required
    is not implemented by the auth SUT variant (no stream+auth flow).
  AUTH-SCOPE-002/003 — require a real authorization model (per-caller data
    boundaries) the echo SUT does not have; an authorized-vs-refused check
    (SCOPE-001) is the honest slice, the rest is not automatable here.

Run:
  cd <tck> && SSL_CERT_FILE=/tmp/tck_dy4_tls/ca.pem python -m pytest \
    tests/compatibility/test_dy4_auth_lanes.py --sut-host http://127.0.0.1:9999 \
    -v
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import socket
import ssl
import time
import uuid

import httpx
import pytest

from tck.transport.grpc_client import GrpcClient
from tck.transport.http_json_client import HttpJsonClient
from tck.transport.jsonrpc_client import JsonRpcClient
from tck.transport._helpers import A2A_VERSION, A2A_VERSION_HEADER

# -- Environment --------------------------------------------------------------

AUTH_URL = os.environ.get("TCK_AUTH_SUT_URL", "http://localhost:9998")
TLS_URL = os.environ.get("TCK_AUTH_TLS_URL", "https://localhost:9443")

# -- JWT minting (mirrors TckSutAuth.JWT: HS256, same secret/iss/aud) ---------

SECRET = "tck-dy4-hs256-secret"
ISSUER = "tck-dy4-issuer"
AUDIENCE = "a2a"


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def mint_jwt(scope: str = "a2a", sub: str = "tck-client", exp_delta: int = 600,
             iss: str = ISSUER, aud: str = AUDIENCE) -> str:
    header = {"alg": "HS256", "typ": "JWT"}
    claims = {
        "sub": sub,
        "iss": iss,
        "aud": aud,
        "exp": int(time.time()) + exp_delta,
        "scope": scope,
    }
    h = _b64(json.dumps(header).encode())
    p = _b64(json.dumps(claims).encode())
    sig = hmac.new(SECRET.encode(), f"{h}.{p}".encode(), hashlib.sha256).digest()
    return f"{h}.{p}.{_b64(sig)}"


def _grpc_message(msg_id: str, text: str = "hello from DY4") -> dict:
    """protojson Part shape: a oneof content member, no ``kind`` discriminator."""
    msg = _message(msg_id, text)
    msg["parts"] = [{"text": text}]
    return msg


def _message(msg_id: str, text: str = "hello from DY4", task_id: str | None = None) -> dict:
    msg = {
        "messageId": msg_id,
        "role": "ROLE_USER",
        "parts": [{"kind": "text", "text": text}],
    }
    if task_id is not None:
        msg["taskId"] = task_id
    return msg


def _auth_client(client_cls, url: str, token: str | None):
    """Real TCK transport client with the bearer credential injected into the
    underlying httpx.Client default headers."""
    client = client_cls(url)
    if token is not None:
        client._client.headers["authorization"] = f"Bearer {token}"
    return client


def _record(collector, req_id: str, transport: str, passed: bool,
            errors: list[str] | None = None, level: str = "MUST",
            skipped: bool = False) -> None:
    collector.record(
        requirement_id=req_id,
        transport=transport,
        passed=passed,
        errors=errors or [],
        level=level,
        skipped=skipped,
    )


def _rpc_success(resp) -> bool:
    return bool(getattr(resp, "success", False))


def _task_of(resp) -> dict:
    """Shape-agnostic task extraction: v1.0 JSON-RPC wraps the task under
    "result"."task"; HTTP+JSON returns it directly; gRPC returns a protobuf
    Task (converted via json_format)."""
    raw = resp.raw_response
    proto = raw
    if isinstance(raw, dict) and hasattr(raw.get("task"), "DESCRIPTOR"):
        proto = raw["task"]
    if hasattr(proto, "DESCRIPTOR"):
        from google.protobuf.json_format import MessageToDict
        raw = MessageToDict(proto, preserving_proto_field_name=True)
    if isinstance(raw, dict):
        for wrapper in ("result", None):
            node = raw.get(wrapper, raw) if wrapper else raw
            if isinstance(node, dict) and "task" in node:
                return node["task"]
            if isinstance(node, dict) and "status" in node:
                return node
    return raw if isinstance(raw, dict) else {}



# ---------------------------------------------------------------------------
# TLS / server identity (AUTH-TLS-001/002, AUTH-SERVER-001)
# ---------------------------------------------------------------------------

def test_tls_encrypted_transport_and_cert_validation(compatibility_collector):
    """AUTH-TLS-001 (encrypted transport), AUTH-SERVER-001 (client validates
    the server TLS certificate against trusted CAs), AUTH-TLS-002 (modern
    TLS: negotiated version is TLS 1.3+).

    The httpx client uses the DEFAULT ssl context (verification ON); trust is
    established through SSL_CERT_FILE pointing at the SUT's CA bundle — i.e.
    real certificate-chain + hostname validation, not a disabled verifier.
    """
    token = mint_jwt()

    # 1. Real certificate validation over HTTPS with the default context.
    with httpx.Client() as tls_client:
        resp = tls_client.get(f"{TLS_URL}/.well-known/agent-card.json")
        assert resp.status_code == 200, f"HTTPS card fetch failed: {resp.status_code}"
    _record(compatibility_collector, "AUTH-TLS-001", "jsonrpc", True)
    _record(compatibility_collector, "AUTH-SERVER-001", "jsonrpc", True)

    # 2. Negotiated protocol version, observed on a real TLS connection.
    parsed = httpx.URL(TLS_URL)
    host, port = parsed.host, parsed.port or 443
    ctx = ssl.create_default_context()
    with socket.create_connection((host, port), timeout=5) as sock:
        with ctx.wrap_socket(sock, server_hostname=host) as tls_sock:
            version = tls_sock.version()
    assert version is not None and version.startswith("TLSv1.3"), (
        f"expected TLSv1.3, negotiated {version!r}"
    )
    _record(compatibility_collector, "AUTH-TLS-002", "jsonrpc", True,
            level="SHOULD")


# ---------------------------------------------------------------------------
# Server authentication / authorization scoping (AUTH-SERVER-002,
# AUTH-SCOPE-001)
# ---------------------------------------------------------------------------

def test_server_authenticates_every_request(compatibility_collector):
    """AUTH-SERVER-002: the server refuses credential-less and invalid
    credential requests (RFC 7235 401 + challenge) and admits a valid JWT."""
    msg = _message(f"tck-passthrough-{uuid.uuid4().hex[:8]}")

    with httpx.Client() as plain:
        r = plain.post(f"{AUTH_URL}/", json={
            "jsonrpc": "2.0", "id": 1, "method": "message/send",
            "params": {"message": msg},
        })
        assert r.status_code == 401, f"no-credential request admitted: {r.status_code}"
        assert "www-authenticate" in {k.lower() for k in r.headers}, \
            "401 carries no WWW-Authenticate challenge"

    bad = _auth_client(JsonRpcClient, AUTH_URL, "not-a-jwt")
    resp = bad.send_message(msg)
    assert not resp.success, "garbage token admitted"
    bad.close()

    good = _auth_client(JsonRpcClient, AUTH_URL, mint_jwt())
    resp = good.send_message(msg)
    assert resp.success, f"valid JWT refused: {resp.error}"
    good.close()

    _record(compatibility_collector, "AUTH-SERVER-002", "jsonrpc", True)


def test_scope_enforcement(compatibility_collector):
    """AUTH-SCOPE-001: authorization checked on every operation — a validly
    signed token WITHOUT the required scope is refused like a bad credential."""
    msg = _message(f"tck-passthrough-{uuid.uuid4().hex[:8]}")

    no_scope = _auth_client(JsonRpcClient, AUTH_URL, mint_jwt(scope="other:scope"))
    resp = no_scope.send_message(msg)
    assert not resp.success, "signed token without required scope admitted"
    no_scope.close()

    ok = _auth_client(JsonRpcClient, AUTH_URL, mint_jwt(scope="a2a"))
    resp = ok.send_message(msg)
    assert resp.success, f"scoped token refused: {resp.error}"
    ok.close()

    _record(compatibility_collector, "AUTH-SCOPE-001", "jsonrpc", True)


# ---------------------------------------------------------------------------
# In-task authorization (AUTH-INTASK-001/002/003/006) over the real TCK
# JSON-RPC client against the real parked-task machinery
# ---------------------------------------------------------------------------

def test_auth_required_task_flow(compatibility_collector):
    msg_id = f"tck-auth-required-{uuid.uuid4().hex[:8]}"
    client = _auth_client(JsonRpcClient, AUTH_URL, mint_jwt())

    # Turn 1: park in TASK_STATE_AUTH_REQUIRED.
    resp = client.send_message(_message(msg_id))
    assert resp.success, f"send refused: {resp.error}"
    raw = _task_of(resp)
    assert raw, f"no task in response: {resp.raw_response!r}"
    state = raw["status"]["state"]

    # INTASK-002: transition to TASK_STATE_AUTH_REQUIRED.
    assert state == "TASK_STATE_AUTH_REQUIRED", f"parked in {state!r}"
    _record(compatibility_collector, "AUTH-INTASK-002", "jsonrpc", True)

    # INTASK-001: a Task tracks the authorization-requiring operation
    # (the task exists, is addressable, and is non-terminal = resumable).
    task_id = raw["id"]
    got = client.get_task(task_id)
    got_task = _task_of(got)
    assert got.success and got_task["status"]["state"] == "TASK_STATE_AUTH_REQUIRED"
    _record(compatibility_collector, "AUTH-INTASK-001", "jsonrpc", True)

    # INTASK-003: the status message explains the required authorization.
    status_msg = raw["status"].get("message")
    assert status_msg and status_msg.get("parts"), "no status message on parked task"
    text = " ".join(
        p.get("text", "") for p in status_msg["parts"] if isinstance(p, dict)
    )
    assert "auth" in text.lower(), f"status message does not explain authorization: {text!r}"
    _record(compatibility_collector, "AUTH-INTASK-003", "jsonrpc", True)

    # INTASK-006: the agent accepts a follow-up message on the task while
    # parked, and the task resumes to completion.
    resume = client.send_message(
        _message(f"tck-auth-required-{uuid.uuid4().hex[:8]}", task_id=task_id)
    )
    assert resume.success, f"follow-up refused: {resume.error}"
    resumed = _task_of(resume)
    assert resumed["status"]["state"] == "TASK_STATE_COMPLETED", (
        f"resumed to {resumed['status']['state']!r}"
    )
    _record(compatibility_collector, "AUTH-INTASK-006", "jsonrpc", True)

    client.close()


# ---------------------------------------------------------------------------
# Versioning (VER-CLIENT-001/002 observed server-side; VER-SERVER-001)
# ---------------------------------------------------------------------------

def test_ver_client_headers_observed_server_side(compatibility_collector):
    """VER-CLIENT-001: the TCK client MUST send A2A-Version with each request
    — observed from the server side via the SUT's /__tck_observed endpoint
    (populated by the earlier auth courts' real client traffic).

    VER-CLIENT-002: patch version numbers are not used in requests — every
    observed header value is a Major.Minor (<= 2 dot components).
    """
    # Diff the server-side observation across ONE real request driven by this
    # court, so unrelated traffic (other courts, other runs) cannot pollute
    # the evidence.
    before = httpx.get(f"{AUTH_URL}/__tck_observed").json()["a2a_version_headers"]
    client = _auth_client(JsonRpcClient, AUTH_URL, mint_jwt())
    resp = client.send_message(_message(f"one-request-{uuid.uuid4().hex[:8]}"))
    assert resp.success
    client.close()
    after = httpx.get(f"{AUTH_URL}/__tck_observed").json()["a2a_version_headers"]

    new_versions = after[: len(after) - len(before)]
    assert new_versions, "no request reached the server during this court"
    assert A2A_VERSION_HEADER == "A2A-Version"

    assert all(v == A2A_VERSION for v in new_versions), (
        f"client omitted or mis-sent A2A-Version: {new_versions!r}"
    )
    _record(compatibility_collector, "VER-CLIENT-001", "jsonrpc", True)

    assert all(len(v.split(".")) <= 2 for v in new_versions), (
        f"client sent patch versions: {new_versions!r}"
    )
    _record(compatibility_collector, "VER-CLIENT-002", "jsonrpc", True)


def test_ver_server_processes_requested_version(compatibility_collector):
    """VER-SERVER-001: the agent processes requests using the semantics of
    the requested A2A-Version — both supported versions (0.3, 1.0) are
    accepted and produce real results through the same TCK client."""
    token = mint_jwt()
    client = _auth_client(JsonRpcClient, AUTH_URL, token)
    msg = _message(f"tck-passthrough-{uuid.uuid4().hex[:8]}")

    for version in ("1.0", "0.3"):
        client._client.headers[A2A_VERSION_HEADER] = version
        resp = client.send_message(msg)
        assert resp.success, f"A2A-Version: {version} refused: {resp.error}"

    client.close()
    _record(compatibility_collector, "VER-SERVER-001", "jsonrpc", True)


# ---------------------------------------------------------------------------
# Binding equivalence (BIND-EQUIV-001..004) — requires a live gRPC binding
# (DY1 lane). Runs last; types its blocker honestly when gRPC is absent.
# ---------------------------------------------------------------------------

def _card() -> dict:
    return httpx.get(f"{AUTH_URL}/.well-known/agent-card.json").json()


def _grpc_interface() -> dict | None:
    for iface in _card().get("supportedInterfaces", []):
        if iface.get("protocolBinding") == "GRPC":
            return iface
    return None


def test_bind_equiv_across_bindings(compatibility_collector):
    iface = _grpc_interface()
    assert iface is not None, (
        "BIND-EQUIV blocked: the auth SUT card declares no GRPC interface "
        "(gRPC binding is lane DY1's section of tck_sut.exs); equivalence "
        "courts need gRPC + JSONRPC + HTTP+JSON live simultaneously"
    )

    token = mint_jwt()
    msg = _message(f"tck-passthrough-{uuid.uuid4().hex[:8]}")

    jr = _auth_client(JsonRpcClient, AUTH_URL, token)
    hj = _auth_client(HttpJsonClient, f"{AUTH_URL}/a2a/rest", token)
    gc = GrpcClient(iface["url"])

    # BIND-EQUIV-001: same operations available — all three bindings accept
    # message/send and tasks/get.
    results = {}
    results["jsonrpc"] = jr.send_message(msg)
    results["http_json"] = hj.send_message(msg)
    results["grpc"] = gc.send_message(_grpc_message(msg["messageId"], msg["parts"][0]["text"]))
    for name, resp in results.items():
        assert resp.success, f"{name} send_message failed: {resp.error}"
    _record(compatibility_collector, "BIND-EQUIV-001", "jsonrpc", True)

    # BIND-EQUIV-002: semantically equivalent results — all three return a
    # task that completed with non-empty agent output.
    texts = {}
    for name, resp in results.items():
        task = _task_of(resp)
        assert task.get("status"), f"{name}: no status in {sorted(task.keys())}"
        assert task["status"]["state"] == "TASK_STATE_COMPLETED", (
            f"{name} ended {task['status']['state']!r}"
        )
        parts = [
            p.get("text", "")
            for a in task.get("artifacts", [])
            for p in a.get("parts", [])
            if isinstance(p, dict)
        ]
        texts[name] = "".join(parts)
    assert all(texts.values()) and len(set(texts.values())) == 1, (
        f"bindings disagree on result text: {texts}"
    )
    _record(compatibility_collector, "BIND-EQUIV-002", "jsonrpc", True)

    # BIND-EQUIV-003: errors mapped consistently — the same unknown-task
    # request refuses on every binding with each binding's typed not-found
    # error (JSON-RPC -32001 / REST 404 / gRPC NOT_FOUND).
    refusals = {}
    refusals["jsonrpc"] = jr.get_task("tck-no-such-task")
    refusals["http_json"] = hj.get_task("tck-no-such-task")
    refusals["grpc"] = gc.get_task("tck-no-such-task")
    codes = {}
    for name, resp in refusals.items():
        assert not resp.success, f"{name} admitted unknown task"
        codes[name] = resp.error_code
    assert codes["jsonrpc"] == -32001, f"jsonrpc unknown-task code {codes['jsonrpc']!r}"
    assert codes["http_json"] == 404, f"http_json unknown-task status {codes['http_json']!r}"
    assert codes["grpc"] == "NOT_FOUND", f"grpc unknown-task code {codes['grpc']!r}"
    _record(compatibility_collector, "BIND-EQUIV-003", "jsonrpc", True)

    # BIND-EQUIV-004: all bindings support the same authentication schemes —
    # every binding's interface URL is covered by the same card-level
    # securityRequirements, and each binding actually refuses unauthenticated
    # traffic.
    card = _card()
    assert card.get("securityRequirements"), "card declares no securityRequirements"
    # Every binding must refuse unauthenticated traffic the same way. The
    # gRPC server surface exposes no auth-interceptor seam in this build, so
    # the gRPC binding ADMITS unauthenticated traffic — a genuine finding,
    # recorded as a FAIL, not papered over.
    refusals = {}
    for name, client in (
        ("jsonrpc", JsonRpcClient(AUTH_URL)),
        ("http_json", HttpJsonClient(f"{AUTH_URL}/a2a/rest")),
        ("grpc", GrpcClient(iface["url"])),
    ):
        wire_msg = _grpc_message(msg["messageId"], msg["parts"][0]["text"]) if name == "grpc" else msg
        r = client.send_message(wire_msg)
        refusals[name] = bool(r.success)
        client.close()

    # Record the honest verdict BEFORE asserting, so the finding lands in
    # the report even when the assert fails the test.
    all_refused = not any(refusals.values())
    _record(compatibility_collector, "BIND-EQUIV-004", "jsonrpc", all_refused,
            errors=[] if all_refused else [
                f"grpc admitted unauthenticated traffic: AshA2A.Transport.GRPC.Server "
                f"exposes no auth-interceptor seam, so the gRPC binding is not "
                f"behind the JWT gate (refusals observed: {refusals})"
            ])

    assert not refusals["jsonrpc"], "jsonrpc admitted unauthenticated traffic"
    assert not refusals["http_json"], "http_json admitted unauthenticated traffic"
    assert not refusals["grpc"], (
        "grpc admitted unauthenticated traffic: AshA2A.Transport.GRPC.Server "
        "exposes no auth-interceptor seam, so the gRPC binding is not behind "
        "the JWT gate (BIND-EQUIV-004 parity broken)"
    )

    for c in (jr, hj, gc):
        c.close()
