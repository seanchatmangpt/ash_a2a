# A2A v1.0 Conformance Statement

What `ash_a2a` claims, and does not claim, about the A2A protocol v1.0.0
wire contract. Every status below is backed by an executed Chicago-style
court (real codecs, real agents, real HTTP conns, zero mocks) in this
repository's test suite. Where reality diverges from the specification,
the divergence is pinned as a `PARTIAL` or `GAP` row, not papered over.

## Scope

- Protocol level: **A2A v1.0.0**.
- Bindings covered: **JSON-RPC 2.0 over HTTP POST**, plus SSE streaming
  for `message/stream` (wrapped `StreamResponse` frames).
- Surface: the in-repo wire codec `AshA2A.Protocol.*`
  (`lib/ash_a2a/protocol/`), the base `AshA2A.Protocol.Plug`, and the
  owned `AshA2A.A2ATransport.Plug` — the same surface documented in
  [A2A endpoint contract](a2a-endpoint-contract.md).
- Out of scope for this statement: push-notification delivery and
  `tasks/resubscribe` replay (owned-transport features with their own
  transport tests, not v1 conformance courts), and the gRPC binding
  (served by `AshA2A.Transport.GRPC.Server`, which landed after these
  courts ran — see [What is not claimed](#what-is-not-claimed)).

## Conformance claims

Legend: `CONFORMANT` — the court passes against the spec requirement.
`PARTIAL` — implemented, but the observed wire behavior differs from or
exceeds the spec in a pinned way. `GAP` — the spec requirement is not
met. "Court" is the specific test in the cited file.

| # | Spec requirement (A2A v1.0) | Status | Court / pinned reality |
| --- | --- | --- | --- |
| 1 | Parts carry exactly one content member, no `kind` discriminator (App. A.2.1); survive a JSON round-trip | CONFORMANT | `test/ash_a2a_v1_conformance_test.exs` court 1 — text+data parts, `Jason` round-trip to identical structs |
| 2 | Events encode as a single-member `StreamResponse` oneof with no `kind` and no `final`; finality reconstructed from terminal states | CONFORMANT | same file, court 2 — all 6 terminal states decode `final == true`, all 3 non-terminal states do not; legacy `final: true` frames still decode (decode-only tolerance) |
| 3 | A2A error codes serialize `google.rpc.ErrorInfo` in `data` (§3.3.2/9.5); no double-wrap | CONFORMANT | same file, court 3 — `-32001..-32004`, `-32602`; relay re-wrap is a no-op; `-32603` keeps free-form data |
| 4 | Agent card v1.0 shape (§8.2): `supportedInterfaces`, no top-level `url`/`protocolVersion` | CONFORMANT | same file, court 4 — real card served by a real `GET /.well-known/agent-card.json` on `AshA2A.Protocol.Plug` |
| 5 | Multi-turn: `message/send` parks in `TASK_STATE_INPUT_REQUIRED`; follow-up on the same `taskId` completes (§7.6) | CONFORMANT | same file, court 5 — real two-turn task, `tasks/get` positive control; a follow-up still missing the argument stays parked |
| 6 | `tasks/list` cursor pagination: `nextPageToken` always present, `""` terminates; pages have no overlap and no gap; `totalSize` counts matches pre-pagination | CONFORMANT | `test/ash_a2a_v1_pagination_test.exs` court A — 3-page sweep over 5 tasks, exact set equality, filter+pagination composition in court C |
| 7 | `pageSize` integer 1..100; out-of-range refused `-32602` naming the field | CONFORMANT | same file, court B — 0 and 101 refused, 1 and 100 accepted |
| 8 | `historyLength` on `tasks/get`: last-N truncation; unset = full history; `0` omits the `history` member; negative refused `-32602` | CONFORMANT | same file, court D |
| 9 | Unknown `status` value and non-string values refused `-32602` | CONFORMANT | same file, court E |
| 10 | Cancel a COMPLETED task → `-32002 TaskNotCancelable` | CONFORMANT | `test/ash_a2a_v1_cancellation_test.exs` court (a) — `tasks/get` before/after shows the refusal changed nothing |
| 11 | Cancel an UNKNOWN task id → `-32001 TaskNotFound` | CONFORMANT | same file, court (c) — indistinguishable from `tasks/get` on the same id (§9.5 parity) |
| 12 | Cancel a non-terminal INPUT_REQUIRED task succeeds → `TASK_STATE_CANCELED` | CONFORMANT | same file, court (d) — cancel succeeds, `tasks/get` and `tasks/list` agree; a follow-up message is refused `-32004` (spec silent; pinned) |
| 13 | Chunked streaming: one stable `artifactId` across chunk frames, `append: true` on chunks 2..N, `lastChunk: true` on the final chunk only | CONFORMANT | `test/ash_a2a_v1_artifact_streaming_test.exs` court (a)/(c) — 3-chunk stream emits exactly 5 frames; `append`/`lastChunk` are emitter-set, not codec-only |
| 14 | The completed task carries the accumulated artifact with parts in stream order | CONFORMANT | same file, court (b) — all chunks folded into one artifact, `["chunk 1", "chunk 2", "chunk 3"]` |
| 15 | A non-streaming reply is one artifact; `append`/`lastChunk` absent | CONFORMANT | same file, court (d) |
| 16 | `append`/`lastChunk` are wire booleans, round-trip through the codec for every combination | CONFORMANT | same file, court (e) — all 4 boolean combinations plus both-keys-absent decode-to-nil |
| 17 | Client-supplied `contextId` honored on turn 1 and preserved on every response; inferred from the task when omitted (§3.4.1/§4.1.4) | CONFORMANT | `test/ash_a2a_v1_context_continuity_test.exs` court (b) — echoed verbatim across 3 turns, including a turn-3 follow-up with no `contextId` |
| 18 | Conversations with different `contextId`s never see each other's history | CONFORMANT | same file, court (c) — interleaved turns, action-observed `prior_turns` counts (3 vs 5) prove isolation |
| 19 | `Task.history` accumulates every prior user+agent message in order | CONFORMANT | same file, court (e) — role sequences `user agent` → `user agent user agent` → 6-message thread, content-asserted |
| 20 | Cancel idempotency (§3.3.1): repeat cancellation has the same effect; a repeat MAY return `TaskNotFound` after purge | CONFORMANT | `test/ash_a2a_v1_cancellation_test.exs` court (e) — the second cancel of an already-canceled task is idempotent success: 200 with the canceled task, and `:ok` at the agent GenServer surface; only an already-terminal non-canceled task still refuses `-32002` |
| 21 | In-flight cancel: the server attempts cancellation, success not guaranteed (§3.1.5) | PARTIAL | same file, court (b) — a real sleeping worker is observable via `tasks/list`; the repo refuses outright `-32002` while the handler is in flight (race-safety: reporting `:canceled` while the effect may still commit would be a false standing). The send then runs to real completion |
| 22 | `tasks/list` request shape per `ListTasksRequest` | PARTIAL | `test/ash_a2a_v1_pagination_test.exs` court D — the repo also accepts `historyLength` on `tasks/list` (the spec defines it only on `tasks/get`) and defaults it to `0`, so listed tasks carry no history unless the client opts in; response `pageSize` echoes the count returned, not the requested cap |
| 23 | Final merged artifact id equals the emitted chunk-sequence id | CONFORMANT | `test/ash_a2a_v1_artifact_streaming_test.exs` court (c) — the fold reuses the pre-minted `:stream_artifact_id` end to end (`lib/ash_a2a/protocol/agent.ex` `stream_done`, `lib/ash_a2a/a2a_transport/plug.ex` `stream_parts`); the court asserts `final_id == hd(chunk_ids)` |
| 24 | Agents MUST reject messages with mismatching `contextId` and `taskId` (§3.4.3/§4.1.4) | CONFORMANT | `test/ash_a2a_v1_context_continuity_test.exs` court (d) — a non-empty request `contextId` differing from the stored one is refused with the typed `-32001` not-found envelope, indistinguishable from an unknown task (§9.5 parity); `tasks/get` agrees the task was never touched |
| 25 | Agents MAY generate a new `contextId` when the message omits one (§3.4.1) | CONFORMANT | same file, court (a) — the server mints `ctx-` + 128 CSPRNG bits (`AshA2A.Transport.Runtime.secure_context_id/0`), non-empty and stable across follow-ups |
| 26 | `TASK_STATE_REJECTED` reachable through the wire | CONFORMANT | `test/ash_a2a_v1_rejected_state_test.exs` — real producer path: authority-gate and capability-resolution refusals land the task terminal `:rejected` with a redacted reason, persisted in the agent's real state, encodes as `TASK_STATE_REJECTED`, wire round-trip, follow-up refused `-32004` |
| 27 | Auth scheme matching is case-insensitive (RFC 7235 §2.1): only `bearer`/`basic` (any case) are extracted; unknown scheme labels still challenge | CONFORMANT | `test/ash_a2a_v1_auth_challenge_test.exs` — lowercase `bearer` and mixed-case `BeArEr` (and lowercase `basic`) prefixes authenticate; `Xauth` still 401s with the `Bearer` challenge |
| 28 | A 401 with multiple applicable schemes carries a challenge for EACH scheme (RFC 7235 §3.1) | CONFORMANT | same file — the OR-requirement court asserts two per-scheme `WWW-Authenticate` headers (`Bearer` + `Basic`) appended, not one replacing the other |
| 29 | A raising auth verify callback fails CLOSED: the caller sees a generic 401, exception detail never on the wire | CONFORMANT | same file — a verify callback that raises yields a halted 401 with the exact `Bearer` challenge; the response body never contains the exception text (`safe_verify/4` in `lib/ash_a2a/protocol/plug/auth.ex`) |

## Verification

Run the courts directly (each exits 0 on conformance):

```bash
mix test test/ash_a2a_v1_conformance_test.exs
mix test test/ash_a2a_v1_pagination_test.exs
mix test test/ash_a2a_v1_cancellation_test.exs
mix test test/ash_a2a_v1_artifact_streaming_test.exs
mix test test/ash_a2a_v1_rejected_state_test.exs
mix test test/ash_a2a_v1_auth_challenge_test.exs
```

`test/ash_a2a_v1_context_continuity_test.exs` is tagged `:serial` (it
drives a real Bandit loopback listener and a shared transport), and the
default `mix test` alias excludes `:serial`. Run it either way:

```bash
mix test test/ash_a2a_v1_context_continuity_test.exs --include serial
# or, for the whole serial tail:
mix test.serial
```

Companion v1 court file (adjacent coverage, not rows above):
`test/ash_a2a_v1_telemetry_test.exs`.

The previously in-flight lanes landed and are covered by runner courts
(`test/ash_a2a_v1_io_modes_test.exs` for per-skill `inputModes`/`outputModes`;
`test/ash_a2a_v1_extended_httpjson_test.exs` and
`test/ash_a2a_v1_push_httpjson_test.exs` for the extended HTTPJSON push
routes) — adjacent coverage, not rows in the claims table above. The gRPC
binding landed after these courts ran (see the TCK section and
[What is not claimed](#what-is-not-claimed)); the TCK compatibility run
is reported in the next section.

Full-suite context: `mix test.all` includes the serial tail; CI runs
`mix test.all --cover`. Machine verdict across all 25 courts at once:
`mix ash_a2a.v1_conformance_report --out receipts/v1-conformance.json`
— at subject `059ff0e3` (2026-10-05T23:24:48Z) it reported **25 PASS /
0 FAIL**; the gate is `totals.fail == 0`.

## A2A TCK compatibility run

The official `a2aproject/a2a-tck` compatibility suite ran against a
real `ash_a2a` SUT server on 2026-10-05 (final post-hardening run,
AT2 lane; reports at `/tmp/a2a-tck/reports/compatibility.json`,
timestamp `2026-10-05T23:17:14Z`, SUT `http://127.0.0.1:9999` driven
by the in-repo-style `tck_sut.exs` on Bandit). Environment: TCK at
`a2aproject/a2a-tck` `main` (external repo, moving ref), Python venv,
`./run_tck.py --sut-host http://127.0.0.1:9999 --transport jsonrpc,http_json`.
Framing: this is a point-in-time compatibility verdict on the
JSONRPC + HTTP+JSON bindings — not TCK certification and not a
verdict on any other binding or release.

Per-transport matrix (from the suite's `compatibility.json`):

| Transport  | Total | Pass | Fail | Skip |
| --- | --- | --- | --- | --- |
| agent_card | 10  | 10 | 0 | 0  |
| jsonrpc    | 96  | 81 | 0 | 15 |
| grpc       | 72  | 0  | 0 | 72 |
| http_json  | 91  | 77 | 0 | 14 |

**Zero test failures on every transport that ran** (agent_card 10/10,
jsonrpc 81/81 run, http_json 77/77 run). The `grpc` transport is
skipped: the served agent card declares the `JSONRPC` interface only
at run time, so the suite has no gRPC endpoint to target; the in-tree
gRPC binding (`AshA2A.Transport.GRPC.Server`, canonical
`lf.a2a.v1.A2AService` — 9 unary RPCs plus the 2 server-streaming
RPCs over HTTP/2) is verified by a real over-the-wire suite
(`test/ash_a2a_transport_grpc_server_test.exs` drives a real gRPC
channel; `test/ash_a2a_transport_grpc_test.exs` covers dispatch and
framing), but the TCK has not been run over gRPC. `http_json` ran
77 tests with 0 failures against the extended card.

Overall compatibility: **76.0%** (MUST 76.4%, SHOULD 63.6%, MAY
100%). Per-requirement: 129 requirements total — 79 PASS, 0 FAIL,
25 SKIPPED, 25 NOT TESTED. The compatibility percentage is a function
of the skipped surface: nothing that executed failed.

What is not counted, and why (the remaining gap to 100% is
entirely not-run surface, not failures):

| Class | Requirements | Why not run |
| --- | --- | --- |
| SKIPPED — gRPC (`GRPC-SVC-*`, `GRPC-ERR-*`, `GRPC-META-*`) | 9 | card declares JSONRPC only; no TCK run over gRPC yet |
| SKIPPED — push (`PUSH-*`) | 11 | card advertises `pushNotifications: false` at run time |
| SKIPPED — stream/capability/extension (`STREAM-SUB-*`, `STREAM-ORDER-*`, `CORE-CAP-*`, `CARD-EXT-*`) | 5 | SUT configuration did not enable those capabilities |
| NOT TESTED — card signing (`CARD-SIGN-*`) | 4 | requires a signed-card setup the SUT did not serve |
| NOT TESTED — auth/TLS (`AUTH-TLS-*`, `AUTH-SERVER-*`, `AUTH-INTASK-*`, `AUTH-SCOPE-*`) | 10 | requires TLS/auth-server prerequisites not present in the run |
| NOT TESTED — verification/binding equivalence (`VER-*`, `BIND-EQUIV-*`) | 7 | requires those setups; not exercised |

### DY4 extension run: auth/TLS/VER-CLIENT/BIND-EQUIV (2026-10-05)

The official suite at pin `263b9cfa` structurally cannot exercise these
requirement IDs: every one of them has `operation: None` and is excluded from
the parametrized runner's parameterization (no dedicated test module covers
them), so they land NOT TESTED regardless of SUT capability. Lane DY4
therefore added an extension court module — `priv/tck/test_dy4_auth_lanes.py`
(copied into the TCK tree at run time so it shares the official
`compatibility_collector`), run against the DY4 auth/TLS SUT variant
`tck_sut_auth.exs` (JWT-gated HTTP listener via the real
`AshA2A.Protocol.Plug.Auth` + HS256/scope, real openssl CA->localhost
server-cert chain over TLS 1.3, an auth-required task flow, a gRPC binding,
and an A2A-Version observation endpoint) with trust established through
`SSL_CERT_FILE` — real chain + hostname validation by the TCK's own httpx,
not a disabled verifier.

Verdict (reports `/tmp/dy4_reports/compatibility.json`, SUT
`http://localhost:9998` + `https://localhost:9443` + gRPC `127.0.0.1:9997`):

| Requirement | Status | Evidence |
| --- | --- | --- |
| AUTH-TLS-001/002, AUTH-SERVER-001 | PASS | real TLS 1.3 handshake, httpx default-context chain+hostname validation of the SUT cert |
| AUTH-SERVER-002, AUTH-SCOPE-001 | PASS | no-credential/garbage/unscoped-token requests refused 401+challenge; scoped JWT admitted |
| AUTH-INTASK-001/002/003/006 | PASS | task parks TASK_STATE_AUTH_REQUIRED with explanatory status message, resumable to completed via same task id over the real TCK client |
| VER-CLIENT-001/002 | PASS | A2A-Version: 1.0 present on every court-driven request (server-side observation diff) |
| VER-SERVER-001 | PASS | both supported versions (0.3, 1.0) processed through the real client |
| BIND-EQUIV-001/002/003 | PASS | same operation/result/typed-error mapping across live JSONRPC + HTTP+JSON + GRPC bindings |
| BIND-EQUIV-004 | FAIL | genuine finding: the gRPC binding admits unauthenticated traffic — `AshA2A.Transport.GRPC.Server` exposes no auth-interceptor seam in this build, so gRPC is not behind the JWT gate the HTTP bindings enforce |
| AUTH-INTASK-004/005, AUTH-SCOPE-002/003 | NOT TESTED | honest blockers: out-of-band credential channel observation, stream maintenance across auth_required, and a real per-caller authorization model are not implemented by the echo SUT variant |

This is an extension-court verdict on the DY4 SUT variant at this pin, not
TCK certification; the official suite's own compatibility.json (section
above) is unchanged.

The MUST-category infrastructure failures from the earlier 2026-10-05
lane-Z19 run (MUST 70.4%: missing `A2A-Version` `-32009` gate,
`tasks/resubscribe` answering `-32004` instead of `-32001` on unknown
tasks, missing card `Cache-Control`/`ETag` per spec §8.6.1) were
fixed in `lib/ash_a2a/transport/plug.ex` and are green in this run —
0 jsonrpc failures (was 5, the echo-SUT class included).

Raw TCK reports (JUnit, HTML, `compatibility.json`) live in
`/tmp/a2a-tck/reports` — session-ephemeral, not committed; re-run the
suite to regenerate them. TCK in CI is a documented refusal
(`REFUSED(ci:tck-not-in-tree)`, `.github/workflows/ci.yml`): the
suite is an external repo at a moving main ref and the SUT is
session-ephemeral, not in this tree.

## What is not claimed

- **A2A TCK certification: not claimed.** The compatibility suite ran
  against the JSONRPC + HTTP+JSON bindings (2026-10-05, section
  above; 76.0% with zero test failures on all run transports, the
  residue being not-run surface — gRPC, push, signed-card, TLS/auth
  setups). `CONFORMANT` in the table still means "the pinned court in
  this repo passes" — not TCK-certified — and the 76.0% figure is a
  point-in-time verdict, not a standing certification.
- **A gRPC conformance claim: not made.** The gRPC binding now exists —
  `AshA2A.Transport.GRPC.Server` serves the canonical
  `lf.a2a.v1.A2AService` (9 unary + 2 server-streaming RPCs over
  HTTP/2), landed after the TCK compatibility run above — but no TCK
  run over gRPC has been executed, and the `protocolBinding` advertised
  in `supportedInterfaces` remains `JSONRPC` only.
- **Semantic-law suites are different things.** `priv/sa2a_conformance/`
  and `mix ash_a2a.sa2a_conformance` / `mix ash_a2a.chicago` qualify the
  SA2A pipeline, not the A2A wire protocol
  (see [Conformance claim](conformance-claim.md) for the RFC-SA2A-007
  verifier, which is likewise not an A2A wire suite).
- **No cross-implementation interop testing** against other A2A v1.0
  servers/clients has been executed; the courts are self-conformance.

## See also

- [A2A endpoint contract](a2a-endpoint-contract.md)
- [A2A spec version mapping](a2a-spec-version-mapping.md)
- [Conformance claim](conformance-claim.md)
- [Conformance profiles](conformance-profiles.md)
