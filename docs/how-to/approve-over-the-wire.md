# Approve Over The Wire

Status: UNVERIFIED. Written without Elixir or Swift toolchains; nothing here was compiled or
run. No row below is CONFORMANT.

The authority service accepts signed human approvals on its `"approve"` op (only when it is
started with a `:mailbox`). The approval is deposited, not trusted: the issuer re-verifies it
when `issue` runs. Submitting grants nothing.

## Wire

One frame per connection, `<<len::32 big-endian, json>>`, answered by one frame over a unix
socket (or mutual TLS):

```json
{"op":"approve","approver":"alice","effect_digest":"sha256:...","generation":9,
 "approval":{"envelope":{"v":1,"alg":"ES256","kid":"...","profile":"classical",
   "signed_bytes_digest":"sha256:...","signature":"<b64url DER>","nonce":"...",
   "not_before":0,"expires":0,"audience":"..."},"message":"<b64url signed bytes>"}}
```

Reply `{"ok":true}` or `{"ok":false,"refusal":"duplicate_approval|malformed_approval|malformed_request|mailbox_full|unknown_op",...}`.

## Elixir client

```elixir
AshA2A.C2.ApproveClient.submit(%{authority_socket: "/run/authority.sock"},
  "alice", effect_digest, generation, approval)
# :ok | {:error, {:refused, code}} | {:error, :authority_transport_refused}
```

With `ctx.c2_tls` (see `AshA2A.C2.L07Tls.Transport`) it uses mutual TLS and never falls back
to the socket.

## sa2a-approver

```bash
swift run sa2a-approver approve --message msg.bin --effect effect.json \
  --key enclave --approver alice --socket /run/authority.sock
```

It applies the normal WYSIWYS gate (digest recomputed locally, summary rendered, biometric
signature) and then submits. Unix socket only; the Swift side has no TLS client.

## What is and is not evidenced

| Claim | Status |
|---|---|
| `ApproveClient` frame and refusal handling | UNVERIFIED, tested only against a stand-in unix-socket peer (`test/ash_a2a/c2/approve_client_test.exs`) |
| `sa2a-approver approve` request shape and framing | UNVERIFIED, tested only against a stand-in peer (`WireApprovalTests.swift`) |
| Interop with the real `AuthorityService.Listener` | NOT TESTED: `authority_service` is not a dependency of this project or of the Swift package. The listener side is covered by `authority_service/test/approver_mailbox_test.exs` |
| Swift-built envelope accepted by the issuer | NOT TESTED (needs a Swift-produced approval fed to the real listener) |
| Mutual TLS from Swift | NOT IMPLEMENTED |
