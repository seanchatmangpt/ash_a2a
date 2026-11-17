# Security review, v26.11.15 (unrun code)

Status: by-eye adversarial review. No Elixir toolchain was available, so nothing here was
compiled or executed. Line numbers refer to the working tree at commit `9c45bb9`
(lane W2-20). The tree moved while the review ran (parallel lanes): `approver_channel/mailbox.ex`
and `authority_service/runtime.ex` gained submit-time verification and a second listener
mid-review; findings below are stated against the newer text where the file changed.
Scope: `lib/ash_a2a/email/plug.ex`, `authority_service/lib/authority_service/{listener,runtime,issuer}.ex`,
`approver_channel/mailbox.ex`, `lib/ash_a2a/c2/l07_tls/transport.ex`,
`lib/ash_a2a/protocol/plug/auth.ex`, `lib/ash_a2a/protocol/agent.ex` (`interrupt_task_worker`),
`lib/ash_a2a/protocol/jsonrpc/request.ex`, `actuator/lib/actuator/{store,wire}.ex`,
`actuator/lib/actuator/wire/{uds,tls}.ex`.

No authentication or authorization bypass was found in the paths reviewed. The findings are
availability, information disclosure, crash-on-input and atomicity gaps.

## Findings

| # | File:line | Severity | Failure scenario | Suggested fix |
|---|---|---|---|---|
| 1 | `lib/ash_a2a/email/plug.ex:111-113` | Medium | The `:stale` branch of `ingest/2` re-parses `conn.body_params`. In `else`, `conn` is the function argument, not the conn rebound by `read_json/2` (which set `body_params`). Whenever the plug reads the body itself (no upstream `Plug.Parsers`), `body_params` is `%Plug.Conn.Unfetched{}`, `Inbound.parse/1` does not return `{:ok, _}`, and the `{:ok, inbound} = ...` match raises `MatchError`: HTTP 500 instead of the 409 and no reconfirm mail. A stale brief therefore errors every time. | Carry `inbound` out of the `with` (return `{:stale, inbound}` from `check_fresh/2`'s caller) instead of re-parsing. |
| 2 | `lib/ash_a2a/email/plug.ex:364,425,433-434` | Medium | `dispatch_one/4` puts `Exception.message(e)` into the result; `summary/1` writes `inspect(r.reason)` into the reply email, and `serialize/1` returns `inspect(reason)` and `inspect(receipt)` in the JSON body. Internal exception text, resource names, and the whole receipt term are disclosed to the sender and to the webhook caller. | Map reasons to a closed atom set for the wire/email; log the detail server-side; return only a receipt id. |
| 3 | `lib/ash_a2a/email/plug.ex:357-366` | Low | `dispatch_one/4` rescues exceptions only. A `throw` or `exit` from the dispatch fun (for example a `GenServer.call` timeout) propagates after `consume/4` already burned the reply tokens (line 105), so the approver gets a 500 and cannot retry. Consuming before dispatch is fail-closed, but the failure is unreported. | Add `catch kind, reason -> refused` and record the result in the ledger so a replay returns it. |
| 4 | `lib/ash_a2a/email/plug.ex:146-148` | Low | A pre-parsed `body_params` skips `:max_body_bytes` (it only bounds the plug's own `read_body`). The depth/node walk still applies, but a large body is already in memory, bounded only by the parser's limit. | Document, or check `conn.req_headers` content-length against `max_body_bytes` first. |
| 5 | `lib/ash_a2a/email/plug.ex:226` | Low | `Keyword.fetch!(opts, :brief_lookup)` is not checked by `require_config/1`. A deployment missing it fails with `KeyError` (500) on the first request instead of the documented 503 refusal. | Add `:brief_lookup` to `require_config/1`. |
| 6 | `lib/ash_a2a/email/plug.ex:215-221` | Low | `bind_approver/2` is a no-op when the brief has no `:approver`: any allowlisted sender holding a valid reply token may approve. Documented, but it is the default. | Make `:approver` required in the brief schema for consequential actions. |
| 7 | `authority_service/lib/authority_service/listener.ex:139-143` | Medium | For TLS the accept loop performs `:ssl.handshake(s, 5_000)` inline, serially. A client with no certificate that connects and stalls blocks the only acceptor for 5 s per connection; one slow connection every 5 s denies all approvers and requesters. The `@max_conns` cap (line 109) is checked only after the handshake. | Hand the transport socket to a spawned process and handshake there (as `actuator/wire/tls.ex:71-79` does). |
| 8 | `authority_service/lib/authority_service/listener.ex:132-133`, `actuator/lib/actuator/wire/tls.ex:88-89` | Low | Any non-`:closed` accept error (for example `:emfile`) loops immediately with no back-off: a hot spin at 100% of a scheduler and a flood of failures. | Sleep briefly (for example 50 ms) before retrying on a non-`:closed` error. |
| 9 | `actuator/lib/actuator/wire/uds.ex:128-129` | Medium | The acceptor returns `:ok` on any `accept` error, including transient `:emfile`/`:econnaborted`. It is `spawn_link`ed to a GenServer that does not trap exits, and a `:normal` exit does not propagate, so the listener stays "up" while it silently accepts nothing; the supervisor never restarts it. | Retry on transient errors; on a fatal error exit with a non-`:normal` reason so the supervisor restarts. |
| 10 | `actuator/lib/actuator/store.ex:140-143` | Low | When the fence refuses with `:unknown_outcome` or `:claim_closed` and the digest and generation match, the store replies `{:ok, %{status: :replayed, ...}}` and the wire returns `"ok": true`. The evidence says `unknown_outcome`, but a client that checks only `ok` treats a possibly-unperformed effect as done. | Return `ok: false` (or a distinct status) for `unknown_outcome`/`executing`; reserve `replayed` for `completed`. |
| 11 | `actuator/lib/actuator/store.ex:119-125,113` | Low | The injected `ctx_fun` runs inside the single Store process. If it raises or blocks, the Store crashes or stalls for every caller (execute is serialized, 30 s call timeout). | Wrap `f.()` in `try/catch` mapping to `{:error, :config_unavailable}`; bound its runtime. |
| 12 | `actuator/lib/actuator/store.ex:257-264` | Low | `{:ok, spec} = EffectorRegistry.fetch(...)` runs after the write-ahead `executing` record. An unregistered type (or a `throw`/`exit` from `perform`, since only `rescue` is used) crashes the Store with the record left `executing`; restart converts it to `unknown_outcome`. Safe, but it burns the instance and drops all in-flight callers. | Fetch the spec before the write-ahead; add `catch` for throw/exit in `perform`. |
| 13 | `actuator/lib/actuator/store.ex:347-384` | Low | `fold/1`'s `case ev["t"]` has no catch-all, and `Map.update!` raises on a `completed` with no `executing`. A journal written by a newer version fails boot with `CaseClauseError` rather than a refusal. | Add `_ -> {:error, ...}` handling and return `{:stop, {:store_boot_refused, ...}}`. |
| 14 | `lib/ash_a2a/protocol/agent.ex:574-584` | Medium | `interrupt_task_worker/2` runs after the canceled task is persisted and then `Process.exit(pid, :kill)`s the worker. If the worker already performed external effects (HTTP call, non-transactional side effect) or its `{:ash_a2a_protocol_task_done, ...}` is already in the mailbox, the effect stands while the task reads `canceled`; the comment promises the effect "never commits". Also only the first worker matching `task_id` is killed (`Enum.find`). | Document that cancel is best-effort for non-transactional effects; kill every matching worker (`Enum.filter`); consider a cooperative cancel signal before `:kill`. |
| 15 | `lib/ash_a2a/protocol/plug/auth.ex:347-354,370-387` | Medium | On the HTTP path a configured `:mtls_header` is trusted unconditionally (only the gRPC path got the `:trust_forwarded_cert` gate, lines 92-97). The header value may be a bare 64-hex SHA-256 fingerprint (line 377-383); a certificate fingerprint is public, so if the endpoint is reachable without a stripping proxy, any client forges that identity with one header. | Apply the same explicit trust flag to the HTTP path, or require the proxy to be named (remote_ip allowlist); drop the bare-fingerprint form unless the flag is set. |
| 16 | `actuator/lib/actuator/wire/uds.ex:136`, `actuator/lib/actuator/wire/tls.ex:96` | Low | `:ok = :gen_tcp.send(...)` (UDS) raises `MatchError` when a client closes early: a crash report per aborted connection. Handler processes are `spawn`ed, not linked or supervised, and neither listener traps exits (`terminate/2` never runs on supervisor shutdown), so in-flight handlers outlive a listener restart and keep calling the Store. | Match the send result and close quietly; link handlers or register them for shutdown. |
| 17 | `actuator/lib/actuator/wire/uds.ex:63-74` | Low | `File.mkdir!`/`File.chmod!`/`File.rmdir!` raise instead of returning `{:error, _}`, so the `bind/1` fallback to `bind_direct/1` is bypassed when the parent directory is unwritable or the stage dir is non-empty after a failed bind; `init/1` crashes with a raise. | Use non-bang calls inside `with` and clean up in `after`. |
| 18 | `authority_service/lib/authority_service/listener.ex:64-66,75` | Low | Staging path is `path <> ".lst/s"` (6 extra bytes); a socket path within 6 bytes of the `sun_path` limit fails to listen, and unlike `actuator/wire/uds.ex` there is no direct-bind fallback. Also `File.rm(path)` and `File.rm_rf(path <> ".lst")` delete whatever is at those paths. | Add the same fallback; refuse to start if `path` is not a socket or absent. |
| 19 | `authority_service/lib/authority_service/listener.ex:157-173,178-183` | Low | `Issuer.issue/3` is a `GenServer.call` with a 15 s timeout. A timeout exit, or a return value outside `{:ok, _} | {:refused, _, _}`, crashes the handler before any reply: the client sees a closed socket with no refusal code. | `try/catch :exit` and reply `refusal(:issuer_unavailable, [])`. |
| 20 | `authority_service/lib/authority_service/approver_channel/mailbox.ex:19,59-62` | Low | Slots and the `seen` set are never evicted (neither on consumption nor TTL). After 1024 accepted approvals the mailbox returns `:mailbox_full` until restart. With submit-time verification (added mid-review) only registered approvers can fill it, so this is now operational rather than attacker-driven. | Delete the slot after `solicit/3` hands it to the Issuer, or expire by `expires`. |
| 21 | `authority_service/lib/authority_service/approver_channel/mailbox.ex` (`verify_with/6`) | Info | Verification now runs in the caller's process per submit; each unauthenticated-to-slot request costs one signature verify plus a registry lookup. Bounded by `max_bytes` and the connection cap, so acceptable. | None. |
| 22 | `authority_service/lib/authority_service/issuer.ex:63-90` | Info | `to_actuator_certificate/1` maps and cross-checks the envelope against the message but does not verify the signature. Safe only when fed Issuer output. | State in the `@doc` that it must never be called on caller-supplied input. |
| 23 | `lib/ash_a2a/c2/l07_tls/transport.ex:83` | Low | Client accepts TLS 1.2 (`versions: [:"tlsv1.3", :"tlsv1.2"]`) while both servers pin 1.3. A downgrade requires a peer that already holds a CA-signed server certificate, so this is hardening only. | Pin `[:"tlsv1.3"]` unless an interop test needs 1.2. |

## Compile-risk list

Verified by reading only; none of these were compiled.

| # | File:line | Risk | Detail | Fix |
|---|---|---|---|---|
| C1 | `actuator/lib/actuator/store.ex:110-151` | Fails `--warnings-as-errors` (high confidence) | Commit a0ce28a inserted `defp resolve_ctx/1` and `defp execute_with/4` between `def handle_call({:execute, ...})` (line 110) and `def handle_call({:reconcile, ...})` (line 151). Elixir warns "clauses of the same name and arity (handle_call/3) must be grouped together". | Move the two `defp`s below the last `handle_call/3` clause (after line 190). |
| C2 | `lib/ash_a2a/protocol/agent.ex:~506-600` | Same class, pre-existing | `defp cancel_active_task` and the new `defp interrupt_task_worker` sit between `handle_call({:cancel, _})` and `handle_call({:get_task, _})` inside the `__using__` quote. The pattern pre-dates this wave (`cancel_active_task`), so it is only a risk if the baseline did not already emit it. | Group the `handle_call/3` clauses if a clean `mix compile --warnings-as-errors` is required. |
| C3 | `lib/ash_a2a/email/plug.ex:112` | Runtime MatchError, not a compile error | See finding 1. | See finding 1. |
| C4 | `lib/ash_a2a/c2/l07_tls/transport.ex:43,46` | Benign | `def send/2` and `def recv/3` shadow `Kernel.send/2` only if called unqualified in this module; they are not. No warning expected. | None. |
| C5 | `actuator/lib/actuator/wire/uds.ex:79` | Benign | `import Bitwise` inside `bind_direct/1` with `&&&` in a `when` guard is valid. | None. |
| C6 | `actuator/lib/actuator/wire.ex:55-58` | Possible `WithClauseError` | The `with` has a single `else` clause `{:error, code} when is_atom(code)`. `Fence.parse/2` returns `Effect.decode`/`Certificate.decode` errors unchanged; any non-`{:error, atom}` shape from those raises in the connection process. Not confirmed (decoders not audited here). | Add `_ -> refuse("parse", :malformed_request)`. |
| C7 | `lib/ash_a2a/protocol/jsonrpc/request.ex` | Clean | `bad_list_bool?/2` and `bad_list_string?/2` added in 5122afd were later removed in favour of `AshA2A.Protocol.ListTasksParams`; no orphan `defp` remains (grep clean), so no unused-function warning. | None. |
| C8 | `authority_service/lib/authority_service/{listener,runtime,issuer}.ex`, `mailbox.ex`, `actuator/lib/actuator/wire/tls.ex`, `lib/ash_a2a/protocol/plug/auth.ex` | No syntax, alias, or unused-variable defect found | `do/end` balance, pattern matches, `with`/`else` shapes, and the `Config` struct's `:channel` key, `Sa2aCrypto.verify_envelope/4`, `Envelope.b64/1` (returns `:error`, handled by the `else _` arms), `SignedMessage.parse/1` and `.digest/1` and `Jcs` (a dependency via `sa2a_crypto`) all resolve. `authority_service/mix.exs` does not list `:jcs` or `:jason` directly (they arrive transitively through `sa2a_crypto`, while `actuator/mix.exs` declares them): works today, but is fragile if `sa2a_crypto` stops exporting them. | Declare `{:jcs, "~> 0.2"}` and `{:jason, "~> 1.4"}` in `authority_service/mix.exs`. |

## Wave 3 re-verification and re-review (lane 16)

Each original finding was re-checked against the current tree. Status values: **fixed** (code
changed in wave 3 or earlier, evidence is a passing test), **handed to lane 09** (code lives in
`authority_service/` or `actuator/`, patch below), **accepted** (documented design, reasoning
given), **obsolete** (code no longer exists in that shape).

| # | Finding | Status | Evidence |
|---|---|---|---|
| 1 | Email plug stale branch re-parse (`MatchError`) | fixed earlier: `stale_with/3` carries `inbound` and the conn out of the `with` (`lib/ash_a2a/email/plug.ex`, `ingest/2`) | `test/email_plug_test.exs` "stale graph digest => 409" |
| 2 | Exception text, reason and receipt term in the email reply and the JSON body | fixed: `public_reason/1` and `public_receipt/1` emit a closed code or a receipt id; detail goes to `Logger` | `test/security_wave3_email_test.exs` (six dispatch outcomes) |
| 3 | `throw`/`exit` from dispatch propagates after tokens are burned | fixed: `catch kind, reason` in `dispatch_one/4` maps to `dispatch_exception` | `test/security_wave3_email_test.exs` (throw, exit) |
| 4 | Pre-parsed body skips `:max_body_bytes` | fixed: declared `content-length` over the bound is 413 | `test/security_wave3_email_test.exs` |
| 5 | `:brief_lookup` not checked by `require_config/1` | fixed: 503 `brief_lookup_unconfigured` | `test/security_wave3_email_test.exs` |
| 6 | `bind_approver/2` no-op without `:approver` | accepted: documented default; a brief that names no approver is open to any allowlisted sender holding the token | none (unchanged) |
| 7 | Authority TLS handshake inline in the accept loop | **handed to lane 09** (still present, see below) | n/a |
| 8 | Hot spin on non-`:closed` accept error | **handed to lane 09** (still present in `listener.ex` and `wire/tls.ex`) | n/a |
| 9 | `wire/uds.ex` acceptor exits `:normal` on any accept error | **handed to lane 09** (still present) | n/a |
| 10-13, 16-22 | Actuator store, wire, mailbox and issuer hardening | not touched: `actuator/` and `authority_service/` belong to lane 09 | n/a |
| 14 | `interrupt_task_worker/2` kills only the first worker | fixed: every worker of the task is stopped. Cancel stays best-effort for non-transactional effects (documented in the code comment) | `test/ash_a2a/protocol/` cancel tests (unchanged, green) |
| 15 | HTTP `:mtls_header` trusted without `:trust_forwarded_cert` | accepted with reasoning: `:mtls_header` is off by default and is itself the documented explicit opt-in on the HTTP path (`docs/how-to/authenticate-agent-requests.md`); requiring a second flag would break that documented configuration, and a forwarded PEM is as forgeable as a fingerprint when the endpoint is reachable without a stripping proxy. gRPC keeps its extra gate because its metadata is client-controlled by default | `test/auth_security_hardening_test.exs` (header ignored unless configured), `test/security_refusals_l13_test.exs` (gRPC gate) |
| 23 | Client accepts TLS 1.2 | not changed: `lib/ash_a2a/c2/l07_tls/transport.ex` belongs to the c2 lanes; hardening only | n/a |
| C1 | `handle_call/3` clauses not grouped in `actuator/store.ex` | lane 09 | n/a |
| C2-C8 | Compile-risk entries | obsolete or benign: the tree compiles (`mix compile` clean of errors); C3 is finding 1 | `mix compile` |

### New findings from the re-review of code added since `a6a98d2`

| # | File | Severity | Finding | Status | Evidence |
|---|---|---|---|---|---|
| W1 | `lib/ash_a2a/sim/mcp/tools.ex` `raw_http/4` | Medium | `a2a_raw_request` appended `path` to the mount URL unchecked: with the `root` mount `path: "@127.0.0.1:PORT/x"` makes the mount userinfo and the request goes to another host (SSRF proxy). The HTTP method was also `String.to_atom/1` of caller input. | fixed: `path` must start with `/` or `?`, not `//`, no space/CR/LF; method is a closed set; gRPC path is checked the same way | `test/security_wave3_mcp_test.exs` (victim listener is never reached) |
| W2 | `lib/ash_a2a/sim/server.ex` | Medium | The sim gRPC listener was started without `:ip`, so it bound every interface while serving the fixed public test tokens. HTTP, push and MCP listeners already bound `127.0.0.1`. | fixed: `AshA2A.Transport.GRPC.Supervisor` takes `:ip`; the sim passes `{127, 0, 0, 1}` | `test/security_wave3_mcp_test.exs` "gRPC port does not answer on a non-loopback interface" (skips silently when the host has no non-loopback address) |
| W3 | `lib/ash_a2a/sim/mcp/http.ex` | Medium | No `Host` check (DNS rebinding), no token option, unbounded session table, `read_body` match crash above 16 MB. `Origin` was already checked. | fixed: loopback `Host` and `Origin` required (403), optional bearer token (`:auth_token` or `ASH_A2A_MCP_TOKEN`, compared with `Plug.Crypto.secure_compare/2`, 401), 256 sessions (429), 413 above 16 MB | `test/security_wave3_mcp_test.exs` "MCP Streamable HTTP" |
| W4 | `lib/ash_a2a/protocol/push_notification_sender/http.ex` | Low | Legacy sender admitted the resolved address then let Req resolve the name again (DNS rebinding window). The `A2ATransport.PushDelivery` path already pinned. | fixed: connects to the admitted address, original name as SNI and `Host` | `test/security_wave3_journal_test.exs` (a name that does not resolve is delivered through the admitted address) |
| W5 | `lib/ash_a2a/task_store/event_journal_ets.ex`, `lib/ash_a2a/protocol/event_journal.ex` | Low | A long-running task was never trimmed (only at terminal), and `trim/3` never deleted the per-generation counter rows: one ETS row per generation forever. | fixed: trim on every advance, counters dropped with their last event | `test/security_wave3_journal_test.exs` (counter rows), `test/ash_a2a/event_journal_writer_test.exs` |
| W6 | `lib/ash_a2a/sim/server.ex` `PushReceiver` | Low | Delivery list and body size unbounded; `{:ok, _} = read_body` crashes above 8 MB. | fixed: newest 1 000 kept, bodies over 1 MB are 413 | `test/security_wave3_mcp_test.exs` |
| W7 | journal replay owner check | Info | `tasks/resubscribe` with `lastSeenGeneration` reaches the journal only after `authorized_task/5` (JSON-RPC), `Ownership.fetch_strict/3` (gRPC) or `owned_task/3` (HTTP+JSON). No hole found. | verified, regression test added | `test/security_wave3_journal_test.exs` "journal replay for a foreign principal" |
| W8 | `Transport.Follow`, `DetachedWatch`, `Task.Delta`, `UnknownMethod`, `Plug.Auth :error_format` | Info | Read for auth bypass, crash-on-input and detail leaks. `Follow` is only entered after the caller's owner check; `DetachedWatch` exits on the idle bound (600 s) and catches agent exits; the `:error_format` bodies carry only the scopes the server declared. No defect found. | reviewed, no change | n/a |
| W9 | Sim tokens | Info | `sim-writer-token`, `sim-reader-token`, `sim-unscoped-token` and the `sim-agent-` prefix are fixed public fixtures (`AshA2A.Sim.Auth` moduledoc says so) and every listener is loopback. They cannot authenticate against a deployment that does not use `AshA2A.Sim.Auth`. | confirmed | `test/security_wave3_mcp_test.exs` |

Not reviewed in depth: the JSON-RPC `SendLiveMessage` handler, `admission_refusal?/1` and the
push-config version gating (read only for owner and tenant checks, which they route through the
same `Ownership`/`authorized_task` seams as the rest). Residual risk: `stdio` MCP has no
authentication by design (the launching client owns the process).

### Handed to lane 09

`authority_service/` and `actuator/` were not edited. Each defect was re-read in the current tree.

**H1. Authority TLS handshake blocks the only acceptor** (Medium).
`authority_service/lib/authority_service/listener.ex:150-155` (`do_accept/1`, `:tls` clause) calls
`:ssl.handshake(s, @recv_timeout)` inside the accept loop (`accept/2`, line 115). Repro: open
`@max_conns` plus one TCP connections to the TLS listener and send nothing; every later client waits
`@recv_timeout` per stalled connection, and the `@max_conns` check (line 118) runs only after the
handshake. Patch: make `do_accept(:tls)` return the transport-accepted socket and handshake in the
spawned handler (as `actuator/lib/actuator/wire/tls.ex:79` already does):

```elixir
defp do_accept(%{kind: :tls, lsock: l}), do: :ssl.transport_accept(l)

# in accept/2, inside the spawned fun, before handle/2:
spawn(fn ->
  try do
    case handshake(st.kind, sock) do
      {:ok, sock} -> handle(st, sock)
      _ -> :ok
    end
  after
    :counters.sub(st.conns, 1, 1)
  end
end)
# handshake(:unix, s) -> {:ok, s}; handshake(:tls, s) -> :ssl.handshake(s, @recv_timeout)
```

(`controlling/3` then moves to the handler too, since the socket is handed over before the
handshake; `close/2` of a transport-accepted socket must use `:ssl.close/1` only after handshake,
see the comment at `actuator/lib/actuator/wire/tls.ex:99`.)

**H2. UDS acceptor exits normally on any accept error** (Medium).
`actuator/lib/actuator/wire/uds.ex:135-136`: `{:error, _} -> :ok`. The acceptor is `spawn_link`ed
(line 31) to a GenServer that does not trap exits, so a `:normal` exit leaves a listener that
accepts nothing. Repro: lower `ulimit -n`, connect until `:emfile`; the acceptor returns and the
socket stays bound. Patch:

```elixir
{:error, :closed} -> :ok
{:error, reason} when reason in [:emfile, :enfile, :econnaborted, :etimedout, :enobufs] ->
  Process.sleep(50)
  accept(lsock, store, ctx_fun, conns)
{:error, reason} -> exit({:uds_accept_failed, reason})
```

**H3. Hot spin on a non-`:closed` accept error** (Low).
`authority_service/lib/authority_service/listener.ex:137-138` and
`actuator/lib/actuator/wire/tls.ex:94-95` retry immediately. Patch: `Process.sleep(50)` before the
recursive `accept/2` call in the `{:error, _}` clause (a failed handshake in H1 already returns
through the handler, so the sleep only affects `transport_accept` failures).
