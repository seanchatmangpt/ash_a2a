# A2A v1.0 Conformance Statement

What `ash_a2a` claims, and does not claim, about the A2A protocol v1.0.1
(wire-compatible with v1.0.0) wire contract. Every status below is
backed by an executed Chicago-style court (real codecs, real agents,
real HTTP conns, zero mocks) in this repository's test suite. Where reality diverges from the specification,
the divergence is pinned as a `PARTIAL` or `GAP` row, not papered over.

## Scope

- Protocol level: **A2A v1.0.1 (wire-compatible with v1.0.0)**. Upstream
  v1.0.1 (2026-05-28) is a clarification release: HTTP+JSON SHOULD use
  `application/a2a+json`, the error HTTP-status table follows
  `google.rpc.Code`, TaskState examples corrected. The vendored
  `priv/a2a_v1_spec_corpus/a2a.proto` is byte-identical to upstream HEAD
  `d18aa92c` (2026-11-13 audit). Rows below were witnessed before the
  v1.0.1 clarifications were audited; rows touched by them are
  re-verified only when a court says so.
- Code now emits `protocolVersion` 1.1 and accepts `A2A-Version` 0.3/1.0/1.1; this
  statement's rows are witnessed at the v1.0 level. Their courts were re-run on 2026-11-16
  (see "Re-run of the row courts" under Verification); v1.1 rows live in
  `a2a-v1-1-conformance.md`.
- A2A 0.3 is legacy/compat only (accepted for interop, not a conformance
  target).
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
| 15 | A non-streaming reply is one artifact in one frame: `append` absent, `lastChunk: true` (it is the artifact's final chunk) | CONFORMANT | same file, court (d) |
| 16 | `append`/`lastChunk` are wire booleans, round-trip through the codec for every combination | CONFORMANT | same file, court (e) — all 4 boolean combinations plus both-keys-absent decode-to-nil |
| 17 | Client-supplied `contextId` honored on turn 1 and preserved on every response; inferred from the task when omitted (§3.4.1/§4.1.4) | CONFORMANT | `test/ash_a2a_v1_context_continuity_test.exs` court (b) — echoed verbatim across 3 turns, including a turn-3 follow-up with no `contextId` |
| 18 | Conversations with different `contextId`s never see each other's history | CONFORMANT | same file, court (c) — interleaved turns, action-observed `prior_turns` counts (3 vs 5) prove isolation |
| 19 | `Task.history` accumulates every prior user+agent message in order | CONFORMANT | same file, court (e) — role sequences `user agent` → `user agent user agent` → 6-message thread, content-asserted |
| 20 | Cancel idempotency (§3.3.1): repeat cancellation has the same effect; a repeat MAY return `TaskNotFound` after purge | CONFORMANT | `test/ash_a2a_v1_cancellation_test.exs` court (e) — the second cancel of an already-canceled task is idempotent success: 200 with the canceled task, and `:ok` at the agent GenServer surface; only an already-terminal non-canceled task still refuses `-32002` |
| 21 | In-flight cancel: the server attempts cancellation, success not guaranteed (§3.1.5) | IMPLEMENTED | `AshA2A.Agent` path: `AshA2A.Transport.Runtime.cancel_in_flight/3` runs the cancel hook, persists `:canceled`, kills the worker and answers the pending send with the canceled task; `test/ash_a2a_v1_cancellation_test.exs` court (b) asserts this over the wire, court (b') the opt-in `execution: [cancel_in_flight: :refuse]` `-32002`. `AshA2A.Protocol.Agent` path: `interrupt_task_worker/2` in `lib/ash_a2a/protocol/agent.ex` kills the default-path worker after the canceled task is persisted; `test/ash_a2a_protocol_agent_inflight_cancel_test.exs`. W2-03: opt-in `admit_first: true` (+ `notify: pid`) on `AshA2A.Protocol.Agent.call/3` persists a fresh send as a task before its worker starts, so `tasks/get` sees it and cancel by id interrupts it; the owner-gated `handle_cancel` refuses another identity (same test file). Remaining: it is opt-in and no transport sets it, so a default wire `message/send` is still stored only when its worker finishes (the client does not know the id until then); custom `handle_cancel/1` hooks that do not stop their own side effects are still best effort |
| 22 | `tasks/list` request shape per `ListTasksRequest` | PARTIAL (the gRPC leg is not driven through a live gRPC server) | Lane W2-09: one shared validator `AshA2A.Protocol.ListTasksParams.validate/1` (`lib/ash_a2a/protocol/list_tasks_params.ex`) refuses wrong-typed or out-of-range `pageSize`, `historyLength`, `timelineLength`, `includeArtifacts`, `contextId`, `pageToken`, `status` and `statusTimestampAfter`; it is called from `JSONRPC.Request.validate_params/1` (-32602), the HTTP+JSON `GET /tasks` handler (400 INVALID_ARGUMENT; `includeArtifacts` now only `true`/`false`, other values are refused instead of read as false) and `JSON.decode_list_tasks_request/1` (`{:error, {:invalid_params, msg}}`). The gRPC `ListTasks` path reaches the same validator through `Dispatch` -> `JSONRPC.handle/3` (INVALID_ARGUMENT 3); `grpc/server.ex` was not edited. Test: `test/ash_a2a/protocol/list_tasks_params_bindings_test.exs` (table-driven through the real JSON-RPC plug, HTTP+JSON plug and gRPC dispatch). Remaining: the gRPC test drives `Dispatch.call/4`, not a live gRPC server; proto-typed fields cannot arrive wrong-typed over the real wire. Correction: `historyLength` IS a real `ListTasksRequest` field upstream; response `pageSize` echoes the requested cap (`authorize_task_list` in `lib/ash_a2a/protocol/plug.ex`) |
| 23 | Final merged artifact id equals the emitted chunk-sequence id | CONFORMANT | `test/ash_a2a_v1_artifact_streaming_test.exs` court (c) — the fold reuses the pre-minted `:stream_artifact_id` end to end (`lib/ash_a2a/protocol/agent.ex` `stream_done`, `lib/ash_a2a/a2a_transport/plug.ex` `stream_parts`); the court asserts `final_id == hd(chunk_ids)` |
| 24 | Agents MUST reject messages with mismatching `contextId` and `taskId` (§3.4.3/§4.1.4) | CONFORMANT | `test/ash_a2a_v1_context_continuity_test.exs` court (d) — a non-empty request `contextId` differing from the stored one is refused with the typed `-32001` not-found envelope, indistinguishable from an unknown task (§9.5 parity); `tasks/get` agrees the task was never touched |
| 25 | Agents MAY generate a new `contextId` when the message omits one (§3.4.1) | CONFORMANT | same file, court (a) — the server mints `ctx-` + 128 CSPRNG bits (`AshA2A.Transport.Runtime.secure_context_id/0`), non-empty and stable across follow-ups |
| 26 | `TASK_STATE_REJECTED` reachable through the wire | CONFORMANT | `test/ash_a2a_v1_rejected_state_test.exs` — real producer path: authority-gate and capability-resolution refusals land the task terminal `:rejected` with a redacted reason, persisted in the agent's real state, encodes as `TASK_STATE_REJECTED`, wire round-trip, follow-up refused `-32004` |
| 27 | Auth scheme matching is case-insensitive (RFC 7235 §2.1): only `bearer`/`basic` (any case) are extracted; unknown scheme labels still challenge | CONFORMANT | `test/ash_a2a_v1_auth_challenge_test.exs` — lowercase `bearer` and mixed-case `BeArEr` (and lowercase `basic`) prefixes authenticate; `Xauth` still 401s with the `Bearer` challenge |
| 28 | A 401 with multiple applicable schemes carries a challenge for EACH scheme (RFC 7235 §3.1) | CONFORMANT | same file — the OR-requirement court asserts two per-scheme `WWW-Authenticate` headers (`Bearer` + `Basic`) appended, not one replacing the other |
| 29 | A raising auth verify callback fails CLOSED: the caller sees a generic 401, exception detail never on the wire | CONFORMANT | same file — a verify callback that raises yields a halted 401 with the exact `Bearer` challenge; the response body never contains the exception text (`safe_verify/4` in `lib/ash_a2a/protocol/plug/auth.ex`) |

## Verification

<!-- rerun-2026-11-16:start -->
### Re-run of the row courts (2026-11-16)

Elixir 1.20.4 / OTP 29.1.1, Postgres on `localhost:55432`. Commit `fea857b5a55fd94d32eb388de2bc218839a6d6aa` (`git rev-parse HEAD`)
plus 1 uncommitted path in the working tree when the run started
(`test/generation_gating_courts_test.exs`, not a court of this statement). Each cited file
was run on its own with `--trace`. A row keeps its status only when the courts it names passed
in this run; otherwise it is PARTIAL and names the failing test. Totals: 27 CONFORMANT, 1 IMPLEMENTED, 1 PARTIAL.

| # | Command and result | Status |
| --- | --- | --- |
| 1 | `mix test test/ash_a2a_v1_conformance_test.exs --include serial --include serial_shard --include serial_solo --trace`: exit 0, 14 passed | CONFORMANT |
| 2 | `mix test test/ash_a2a_v1_conformance_test.exs --include serial --include serial_shard --include serial_solo --trace`: exit 0, 14 passed | CONFORMANT |
| 3 | `mix test test/ash_a2a_v1_conformance_test.exs --include serial --include serial_shard --include serial_solo --trace`: exit 0, 14 passed | CONFORMANT |
| 4 | `mix test test/ash_a2a_v1_conformance_test.exs --include serial --include serial_shard --include serial_solo --trace`: exit 0, 14 passed | CONFORMANT |
| 5 | `mix test test/ash_a2a_v1_conformance_test.exs --include serial --include serial_shard --include serial_solo --trace`: exit 0, 14 passed | CONFORMANT |
| 6 | `mix test test/ash_a2a_v1_pagination_test.exs --include serial --include serial_shard --include serial_solo --trace`: exit 0, 17 passed | CONFORMANT |
| 7 | `mix test test/ash_a2a_v1_pagination_test.exs --include serial --include serial_shard --include serial_solo --trace`: exit 0, 17 passed | CONFORMANT |
| 8 | `mix test test/ash_a2a_v1_pagination_test.exs --include serial --include serial_shard --include serial_solo --trace`: exit 0, 17 passed | CONFORMANT |
| 9 | `mix test test/ash_a2a_v1_pagination_test.exs --include serial --include serial_shard --include serial_solo --trace`: exit 0, 17 passed | CONFORMANT |
| 10 | `mix test test/ash_a2a_v1_cancellation_test.exs --include serial --include serial_shard --include serial_solo --trace`: exit 0, 6 passed | CONFORMANT |
| 11 | `mix test test/ash_a2a_v1_cancellation_test.exs --include serial --include serial_shard --include serial_solo --trace`: exit 0, 6 passed | CONFORMANT |
| 12 | `mix test test/ash_a2a_v1_cancellation_test.exs --include serial --include serial_shard --include serial_solo --trace`: exit 0, 6 passed | CONFORMANT |
| 13 | `mix test test/ash_a2a_v1_artifact_streaming_test.exs --include serial --include serial_shard --include serial_solo --trace`: exit 0, 7 passed | CONFORMANT |
| 14 | `mix test test/ash_a2a_v1_artifact_streaming_test.exs --include serial --include serial_shard --include serial_solo --trace`: exit 0, 7 passed | CONFORMANT |
| 15 | `mix test test/ash_a2a_v1_artifact_streaming_test.exs --include serial --include serial_shard --include serial_solo --trace`: exit 0, 7 passed | CONFORMANT |
| 16 | `mix test test/ash_a2a_v1_artifact_streaming_test.exs --include serial --include serial_shard --include serial_solo --trace`: exit 0, 7 passed | CONFORMANT |
| 17 | `mix test test/ash_a2a_v1_context_continuity_test.exs --include serial --include serial_shard --include serial_solo --trace`: exit 0, 5 passed | CONFORMANT |
| 18 | `mix test test/ash_a2a_v1_context_continuity_test.exs --include serial --include serial_shard --include serial_solo --trace`: exit 0, 5 passed | CONFORMANT |
| 19 | `mix test test/ash_a2a_v1_context_continuity_test.exs --include serial --include serial_shard --include serial_solo --trace`: exit 0, 5 passed | CONFORMANT |
| 20 | `mix test test/ash_a2a_v1_cancellation_test.exs --include serial --include serial_shard --include serial_solo --trace`: exit 0, 6 passed | CONFORMANT |
| 21 | `mix test test/ash_a2a_v1_cancellation_test.exs --include serial --include serial_shard --include serial_solo --trace`: exit 0, 6 passed; `mix test test/ash_a2a_protocol_agent_inflight_cancel_test.exs --include serial --include serial_shard --include serial_solo --trace`: exit 0, 3 passed | IMPLEMENTED |
| 22 | `mix test test/ash_a2a/protocol/list_tasks_params_bindings_test.exs --include serial --include serial_shard --include serial_solo --trace`: exit 0, 37 passed | PARTIAL |
| 23 | `mix test test/ash_a2a_v1_artifact_streaming_test.exs --include serial --include serial_shard --include serial_solo --trace`: exit 0, 7 passed | CONFORMANT |
| 24 | `mix test test/ash_a2a_v1_context_continuity_test.exs --include serial --include serial_shard --include serial_solo --trace`: exit 0, 5 passed | CONFORMANT |
| 25 | `mix test test/ash_a2a_v1_context_continuity_test.exs --include serial --include serial_shard --include serial_solo --trace`: exit 0, 5 passed | CONFORMANT |
| 26 | `mix test test/ash_a2a_v1_rejected_state_test.exs --include serial --include serial_shard --include serial_solo --trace`: exit 0, 5 passed | CONFORMANT |
| 27 | `mix test test/ash_a2a_v1_auth_challenge_test.exs --include serial --include serial_shard --include serial_solo --trace`: exit 0, 24 passed | CONFORMANT |
| 28 | `mix test test/ash_a2a_v1_auth_challenge_test.exs --include serial --include serial_shard --include serial_solo --trace`: exit 0, 24 passed | CONFORMANT |
| 29 | `mix test test/ash_a2a_v1_auth_challenge_test.exs --include serial --include serial_shard --include serial_solo --trace`: exit 0, 24 passed | CONFORMANT |
<!-- rerun-2026-11-16:end -->

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
`mix test.all --cover`. Machine verdict across all courts at once:
`mix ash_a2a.v1_conformance_report --out receipts/v1-conformance.json`
— `v1_courts/0` in `lib/mix/tasks/ash_a2a.v1_conformance_report.ex` yields
36 court files at this tree. Historical witnessed runs: 25 PASS / 0 FAIL
(25 courts) at subject `059ff0e3` (2026-10-05); 26 PASS / 0 FAIL at
`a9cc903b` and `13622178` (see [TCK suite](tck-suite.md)). The count is
derived from a glob of `test/ash_a2a_v1_*_test.exs` minus two explicit
exclusions (38 files on disk, 2 excluded); a court count in prose is
re-checked by `test/tck_assert_script_test.exs`. Re-run the report to renew
a verdict at the current head; the gate is `totals.fail == 0`.

## A2A TCK compatibility run

### Current run (2026-11-17, TCK `104a7b4a`, subject `ash_a2a` 26.11.13 + working tree)

Real upstream run of `a2aproject/a2a-tck` at commit
`104a7b4ae0d83f65c075e3793e322953a830eaba` (2026-11-06, "require Python 3.15+")
against `tck_sut.exs` (real `AshA2A.Agent` behind the real JSON-RPC, HTTP+JSON
and gRPC transports on Bandit/gRPC listeners, ports 19907/19908), Python 3.15.0b4
venv, `./run_tck.py --sut-host http://127.0.0.1:19907 --transport
jsonrpc,http_json,grpc`. Repeated twice with identical results. This TCK's
vendored specification is the 1.0.x text (it says "Latest Released Version
1.0.0"); it has no v1.1 requirement set, so this is a point-in-time wire
compatibility record for a v1.1 server against 1.0.x requirements, not a v1.1
verdict and not TCK certification.

Requirement-level record `{pass, fail, not_tested, skipped, manual}` over 133
requirements: **`{99, 1, 18, 6, 9}`** (MUST 87 pass / 0 fail / 5 skipped / 7
manual / 16 not tested; SHOULD 8 / 1 / 1 / 2 / 2; MAY 4 pass). Automated score
83.9% (MUST 84.5%, SHOULD 72.7%, MAY 100%), with not-tested in the
denominator. Test-level: 240 passed, 2 failed, 21 skipped (3 of the skips are
the runner's "no requirements at this level" placeholders).

Per binding (requirement x binding cells; not_tested and manual are
requirement-level and have no binding):

| Binding | pass | fail | skipped |
| --- | --- | --- | --- |
| agent_card | 8 | 0 | 1 |
| jsonrpc | 76 | 0 | 5 |
| http_json | 74 | 1 | 3 |
| grpc | 59 | 0 | 1 |

The single failing requirement is `HTTP_JSON-SVC-001` (SHOULD, "Content-Type
is application/a2a+json"; two tests: success and error responses on
http_json). It is a TCK contradiction, not a library defect: the MUST
`HTTP_JSON-ERR-001` requires the substring `application/json` in an error
response's Content-Type, which `application/a2a+json` (and spec v1.1.0-rc's
`application/problem+json` error examples) do not contain, so no error
response can satisfy both. The SUT keeps the library default
`application/json` so the MUST holds; the library serves `application/a2a+json`
when configured (`content_type:`) or when the request `Accept`s it (spec
section 14.1.1; "SHOULD" at the HTTP+JSON binding text). `scripts/tck_assert.py`
reports `pass=99 fail=1 not_tested=18 skipped=6 manual=9 must_fail=0`.
`run_tck.py` itself exits 1 because of that SHOULD failure. The failure is
recorded in `scripts/tck_expected_failures.json` (it cannot be fixed without
breaking the MUST: the only common string needs a parameter that spec 14.1.1
forbids), `scripts/tck_assert.py --expected-failures` tolerates only that id and
fails if it starts passing, and the `tck` CI job uses it; with it the assert
prints `... must_fail=0 expected_fail=1 unexpected_fail=0` and exits 0. See
[TCK suite](tck-suite.md#expected-tck-failures); the unposted upstream report
text is [tck-upstream-issue-draft.md](tck-upstream-issue-draft.md). The CI pin
(`TCK_PIN_SHA`) is `104a7b4a`, the commit this run used and the only one the
expected-failure entry names (the former pin `263b9cfa` is historical; the
entry would not apply there).

Not-tested requirements (no test exists in the TCK at this commit):
`AUTH-SERVER-002`, `AUTH-INTASK-001..006`, `AUTH-SCOPE-001..003`,
`VER-CLIENT-001`, `VER-SERVER-001`, `VER-CLIENT-002`, `BIND-EQUIV-001..004`,
`GRPC-SVC-003`. Manual (marked not-automatable): `CARD-CLIENT-001`,
`CARD-SIGN-001..004`, `AUTH-TLS-001/002`, `AUTH-SERVER-001`, `BIND-CUSTOM-002`.

Skipped tests, with the TCK's own reason (JUnit `skipped` message). Those
marked "capability" are skipped because the SUT declares the capability, so
the negative probe is inapplicable:

| Test | Binding | Reason |
| --- | --- | --- |
| `test_custom_binding_identifiers_are_uris` (BIND-CUSTOM-001) | agent_card | Agent Card declares no custom binding |
| `test_push_not_supported_jsonrpc` / `_rest` (CORE-CAP-001) | jsonrpc, http_json | Agent supports push notifications (capability) |
| `test_streaming_not_supported_jsonrpc` (CORE-CAP-002) | jsonrpc | Agent supports streaming (capability) |
| `test_extended_card_not_supported_jsonrpc` (CORE-CAP-003) | jsonrpc | Agent supports extended agent card (capability) |
| `test_missing_required_extension_returns_error_jsonrpc` / `_http_json` (CORE-CAP-004) | jsonrpc, http_json | Card does not declare `urn:a2a:tck:required-extension` as required |
| `test_extended_card_not_configured_jsonrpc` / `_http_json` / `_grpc` (CARD-EXT-002) | all three | Extended card is configured (precondition does not hold) |
| `test_unsupported_operation_returns_failed_precondition` | grpc | Agent supports streaming |
| `test_push_not_supported_returns_failed_precondition` | grpc | Agent supports push notifications |
| `test_unsupported_operation_returns_400` | http_json | Agent supports streaming |
| `test_content_type_not_supported_returns_400` | http_json | Agent declares support for the media type used by the probe (card `defaultInputModes` is `*/*`) |
| `test_push_not_supported_returns_400` | http_json | Agent supports push notifications |
| `test_push_notification_not_supported_error` | jsonrpc | Agent supports push notifications; cannot trigger -32003 |
| `test_unsupported_operation_error` | jsonrpc | Agent supports streaming; cannot trigger -32004 |
| `test_content_type_not_supported_error` | jsonrpc | Server did not return an error for wrong Content-Type |
| `test_should_requirement[no-requirements-*]` (3) | all three | No requirements at this level |

This closes the former open item that the skipped IDs were unrecoverable for
the old pin: they are reproducible from the table above (the old pin's 31 are
not recoverable and are not claimed to match).

What changed in the SUT harness (`tck_sut.exs`, not library code) to get here:
the first run at this commit had 83 failures because the SUT process crashed
on the first push delivery: the harness (`--no-start`) did not start
`AshA2A.Protocol.PushTaskSupervisor` nor the `:req` application
(`Req.FinchSupervisor`, which the sender's DNS-pinned per-delivery pools use);
both are now started. The REST `message:send` wrapper returned `:ok` instead of
the `%Plug.Conn{}`, making Bandit reset the connection on the push follow-up
(three intermittent http_json push failures); it now returns the conn. The
card advertises `*/*` input modes with library input-mode admission left ON:
the TCK's MUST probe `CORE-SEND-003` (generic runner, no expected error) needs
a normal response for an unlisted part mediaType, while the http_json status
probe expects `ContentTypeNotSupportedError` only for cards that do not
advertise the type; the library's own refusal path is covered by its own
tests. Raw reports are session-ephemeral (`/tmp/tck_reports7/run{1,2}/`), not
committed.

**Staleness notice (2026-11-13).** Every TCK figure below the "Current run" subsection
(including the 79.0% and 73.6% percentages) is bound to the old pin
`263b9cfa` (the former `TCK_PIN_SHA` in `.github/workflows/ci.yml`, since moved to `104a7b4a`) and the dated
subject named beside it; it is stale for the current tree and for
upstream spec v1.0.1. The TCK has no GitHub release; its `main` is five
commits past the pin, including `70f6f73c` (#258: aligns to 1.0.1,
re-validates nine error mappings, keeps not-tested in the denominator,
reports MANUAL separately) and needs Python 3.15+. Until a re-run at
`70f6f73c` lands, the record form is
`{pass, fail, not_tested, skipped, manual}` + pin SHA + date, not a
percentage headline. Percentages below are historical.

Latest recorded tuple (pin `263b9cfa`, 2026-10-13, subject `13622178`):
`{pass: 234, fail: 0, not_tested: n/r, skipped: 31, manual: n/r}`
(`n/r` = not recorded in that run's notes; UNVERIFIED).

### Final verdict (2026-10-06, branch `feat/tck-vuln-hardening`, HEAD `cadb6534`)

The full suite re-ran against the real `ash_a2a` SUT after the
vuln-hardening fixes landed: **235 passed / 30 skipped / 0 FAIL,
MUST 87/87, SHOULD 7/7, MAY 4/4 — overall 79.0%**. Zero failing
requirements remain: the earlier enumerated gaps (push-lifecycle,
gRPC extended-card, gRPC stream-close isolation, gRPC unauthenticated
admission) are all green at this tree.

### Refresh verdict (2026-10-13, branch `main`, HEAD `13622178`)

The full suite re-ran against the real SUT after the pagination fixes
(page_size echo, historyLength on tasks/get-only, authorize_task_list
filter, commit `13622178`) landed on main. TCK pinned at `263b9cfa`
(then the CI pin; note the pinned layout installs via `pip install -e .` —
there is no `requirements.txt` at this SHA). Environment deltas vs the
2026-10-06 run: SUT HTTP on `:19999` and gRPC on `:20000`
(`TCK_SUT_GRPC_PORT=20000`) because a local Docker proxy was occupying
`127.0.0.1:10000`; command
`./run_tck.py --sut-host http://127.0.0.1:19999 --transport jsonrpc,http_json,grpc`.

**234 passed / 31 skipped / 0 failed (test level); MUST 87 PASS /
0 FAIL, SHOULD 7 PASS / 0 FAIL, MAY 4 PASS / 0 FAIL — overall 79.0%**
(MUST 79.8%, SHOULD 63.6%, MAY 100%). Zero failing requirements (the
suite's FAILED REQUIREMENTS section was empty; note the console
table's "Failed" column counts not-evaluated requirements, i.e.
total − passed − skipped). Per-transport: agent_card 10/10, jsonrpc
91/98 (7 skip), http_json 83/88 (5 skip), grpc 68/71 (3 skip).

Comparison against the 2026-10-06 verdict at `cadb6534`: identical
overall compatibility (79.0%) and identical per-level requirement pass
counts (MUST 87, SHOULD 7, MAY 4, 0 failing); the pagination changes
introduced **no TCK regression**. Test-level counts shifted 235/30/0 →
234/31/0: one additional environment-dependent test skip, no
requirement flipped status. Raw reports: `/Users/sac/a2a-tck/reports/`
(session-ephemeral).

### Which tests are skipped, and why (lane L16, UNVERIFIED)

**The 31 skipped test IDs and their skip reasons are not recoverable
from this repository.** The raw reports (JUnit, HTML,
`compatibility.json`) were session-ephemeral and are not committed;
`reports/` does not exist in the tree, and no toolchain or TCK checkout
was available when this section was revised. What the recorded notes
support, and no more:

- Per-transport skips from the 2026-10-13 run: jsonrpc 7, http_json 5,
  grpc 3 (15 transport-level rows). The remaining 16 of the 31
  test-level skips are not attributed to any transport or requirement
  in the notes.
- The earlier 2026-10-05 run recorded 4 requirement-level skips,
  `CORE-CAP-*`, with the reason "SUT configuration did not enable those
  capabilities". Which capability each one probes was not recorded, so
  it cannot be said whether the current `tck_sut.exs` (streaming, push
  notifications and the extended card advertised) still skips them.
- The 2026-10-13 notes call one extra skip (30 to 31) "environment
  dependent"; that attribution is unverified.

Consequence: no SUT change was made in `tck_sut.exs` or
`tck_sut_auth.exs` for this gap. Enabling a capability without knowing
which skip it unblocks would be guesswork, and nothing could be run to
check it. The gap is narrowed to "unattributed", not closed.

To attribute the skips, re-run the suite at the current pin and keep
the reports: use the command above with `pytest -rs` (or read the
`<skipped message=...>` elements of the JUnit XML), then classify each
skip as server-feasible (a capability or behaviour the SUT could
enable), TCK-side (needs a client, TLS or auth prerequisite the main
SUT lacks; DY4 covers some of those), or environmental. Only then
change the SUT, and record the new tuple with its pin SHA and date.
This remains UNVERIFIED and is not TCK certification.

## Earlier run (2026-10-05, G6 integration tree `2379635c`)

The official `a2aproject/a2a-tck` compatibility suite ran against a
real `ash_a2a` SUT server on 2026-10-05 (final G6 integration run;
reports at `/tmp/a2a-tck/reports/compatibility.json`, timestamp
`2026-10-06T01:30:52Z`, SUT `http://127.0.0.1:9999` (HTTP+JSON-RPC on
Bandit) + gRPC on `127.0.0.1:10000`, driven by the in-repo
`tck_sut.exs`, which now serves a JWS-signed card, the extended-card
endpoint, push-config RPCs, and a gRPC `A2AService` handler).
Environment: TCK at `a2aproject/a2a-tck` `main` (external repo,
moving ref), Python venv,
`./run_tck.py --sut-host http://127.0.0.1:9999 --transport
jsonrpc,http_json,grpc`. Framing: this is a point-in-time
compatibility verdict on all three wire bindings — not TCK
certification and not a verdict on any release. The run happened on a
branch tip `2379635c` (the G6 final integration tree).

Per-transport matrix (from the suite's `compatibility.json`):

| Transport  | Total | Pass | Fail | Skip |
| --- | --- | --- | --- | --- |
| agent_card | 10  | 10 | 0 | 0  |
| jsonrpc    | 98  | 88 | 3 | 7  |
| grpc       | 62  | 53 | 7 | 2  |
| http_json  | 86  | 77 | 4 | 5  |

Overall compatibility: **73.6%** (MUST 73.6%, SHOULD 63.6%, MAY
100%). Per-requirement: 129 requirements total — 92 PASS, 7 FAIL,
4 SKIPPED, 26 NOT TESTED.

Reconciliation (derived only from the rows above; two different units):

- The table counts **tests per transport**, not requirements. Column
  sums: 256 tests, 228 pass, 14 fail, 14 skip (each row sums to its
  total: 88+3+7=98, 53+7+2=62, 77+4+5=86). The 14 failing tests are
  the same failures seen once per transport.
- The 7 FAIL / 92 PASS figures count **distinct requirements**
  (92+7+4+26=129). 14 failing tests and 7 failing requirements are
  therefore not a contradiction; the table does not map tests to
  requirements, so the 14 -> 7 collapse is UNVERIFIED beyond the
  enumeration of 7 requirements below.
- 73.6% = 92 PASS / (129 total - 4 SKIPPED) = 92/125. NOT TESTED
  stays in that denominator. The per-level split (MUST 73.6%, SHOULD
  63.6% = 7/11, MAY 100% = 4/4) implies MUST 81/110; the per-level
  counts are UNVERIFIED (not printed in this doc's rows).
- The 79.0% runs (2026-10-06 / 2026-10-13) use 98 PASS (MUST 87 +
  SHOULD 7 + MAY 4); 98/124 = 79.0%, consistent with MUST 87/109 =
  79.8%. The 124 denominator is inferred from the percentages, not
  recorded; UNVERIFIED.
- A 69.2% figure does not appear anywhere in this document and is not
  derivable from its rows; it is not claimed.
- Reproduce (needs a local `a2aproject/a2a-tck` checkout at pin
  `263b9cfa`): `./run_tck.py --sut-host http://127.0.0.1:19999
  --transport jsonrpc,http_json,grpc`, then read
  `reports/compatibility.json`.

Failing requirement classes (7 FAIL, all enumerated — none silent):

| Class | Requirements | Observed reality |
| --- | --- | --- |
| FAIL — push (`PUSH-CREATE-001`, `PUSH-DELIVER-001/002/003`) | 4 | push-config creation fails (`Internal error` over gRPC; `400 Push Notification is not supported` over http_json) and the TCK's webhook observer receives no delivery — the push-lifecycle lane's TCK-webhook delivery path had not fully landed at run time |
| FAIL — extended card over gRPC (`CARD-EXT-001/002`) | 2 | authenticated `GetExtendedAgentCard` answers `UNIMPLEMENTED` over the gRPC binding at that run (since addressed by the SUT extended-card callback; re-run UNVERIFIED) (HTTP+JSON serves the endpoint; the gRPC handler had not implemented extended-card RPCs at run time) |
| FAIL — gRPC stream-close isolation (`STREAM-ORDER-004`) | 1 | after one subscriber disconnects, a second subscriber on the same task received no further events over gRPC |

What is not counted (not-run surface, not failures):

| Class | Requirements | Why not run |
| --- | --- | --- |
| NOT TESTED — auth/TLS (`AUTH-*`) | 13 | requires TLS/auth-server prerequisites absent from the main SUT; exercised instead by the DY4 extension run below |
| NOT TESTED — verification/binding equivalence (`VER-*`, `BIND-*`) | 7 | partially covered by the DY4 extension run below; the official runner does not parameterize these IDs |
| NOT TESTED — card signing (`CARD-SIGN-*`) | 4 | the SUT card IS signed (DY3); the official runner does not parameterize these IDs |
| SKIPPED — core capability (`CORE-CAP-*`) | 4 | SUT configuration did not enable those capabilities |

Progress against the earlier 2026-10-05 runs: the MUST-category
infrastructure failures from the lane-Z19 run (missing `A2A-Version`
`-32009` gate, `tasks/resubscribe` answering `-32004` instead of
`-32001` on unknown tasks, missing card `Cache-Control`/`ETag` per
spec §8.6.1) remain green. The G3 streaming lane converted the
subscribe surface — `STREAM-SUB-001/002/003` and
`STREAM-ORDER-001/002/003` now PASS across all three transports
(`tasks/resubscribe` streams transport-backed replay,
`lib/ash_a2a/a2a_transport/sse.ex`) — and the DY3 signed-card lane
put the card-signing surface on the wire (SUT card carries JWS
`signatures`).

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
| VER-SERVER-001 | PASS | both supported versions (1.0 target; 0.3 legacy/compat only) processed through the real client |
| BIND-EQUIV-001/002/003 | PASS | same operation/result/typed-error mapping across live JSONRPC + HTTP+JSON + GRPC bindings |
| BIND-EQUIV-004 | FAIL (historical, 2026-10-05 build) | at that build the gRPC binding admitted unauthenticated traffic with no auth-interceptor seam; `AshA2A.Transport.GRPC.Server` now carries an optional `auth: {module, opts}` seam (`auth!/1`, `lib/ash_a2a/transport/grpc/server.ex`). This extension run has not been repeated |
| AUTH-INTASK-004/005, AUTH-SCOPE-002/003 | NOT TESTED | honest blockers: out-of-band credential channel observation, stream maintenance across auth_required, and a real per-caller authorization model are not implemented by the echo SUT variant |

This is an extension-court verdict on the DY4 SUT variant at this pin, not
TCK certification; the official suite's own compatibility.json (section
above) is unchanged.

The MUST-category infrastructure failures from the earlier 2026-10-05
lane-Z19 run (missing `A2A-Version` `-32009` gate,
`tasks/resubscribe` answering `-32004` instead of `-32001` on unknown
tasks, missing card `Cache-Control`/`ETag` per spec §8.6.1) were
fixed in `lib/ash_a2a/transport/plug.ex` and are green in this run —
0 jsonrpc failures of that class.

Raw TCK reports (JUnit, HTML, `compatibility.json`) live in
`/tmp/a2a-tck/reports` — session-ephemeral, not committed; re-run the
suite to regenerate them. TCK in CI: the `tck` job now exists in
`.github/workflows/ci.yml` (commit `6342ab2d`) running the official
suite against the in-tree SUT; the earlier
`REFUSED(ci:tck-not-in-tree)` framing is retired.

## What is not claimed

- **A2A TCK certification: not claimed.** (All percentages here are
  stale, bound to pin `263b9cfa`; see the staleness notice in the TCK
  section.) The compatibility suite ran
  against all three bindings — latest point-in-time verdict 2026-10-13
  at `13622178` on main (**79.0%** overall, 234 passed / 31 skipped /
  0 FAIL, MUST 87, SHOULD 7, MAY 4, 0 failing, section above); the
  2026-10-06 run at `cadb6534` was **79.0%** (235 passed / 30 skipped /
  0 FAIL) and the earlier 2026-10-05 run was **73.6%**
  overall, 92 PASS / 7 FAIL / 4 SKIPPED / 26 NOT TESTED. Point-in-time
  verdicts, not a standing certification.
  `CONFORMANT` in the table still means "the pinned court in
  this repo passes" — not TCK-certified — and the 73.6% figure is a
  point-in-time verdict, not a standing certification.
- **A gRPC conformance claim: not made.** The gRPC binding exists —
  `AshA2A.Transport.GRPC.Server` serves the canonical
  `lf.a2a.v1.A2AService` (9 unary + 2 server-streaming RPCs over
  HTTP/2). The 2026-10-13 TCK run reported grpc 68/71 (3 skip, 0
  failing requirements); the in-repo gRPC court is
  `test/ash_a2a_v1_grpc_must_test.exs`. The `protocolBinding` advertised
  in `supportedInterfaces` remains `JSONRPC` only, and no gRPC
  conformance table rows exist in this statement.
- **Semantic-law suites are different things.** `priv/sa2a_conformance/`
  and `mix ash_a2a.sa2a_conformance` / `mix ash_a2a.chicago` qualify the
  SA2A pipeline, not the A2A wire protocol
  (see [Conformance claim](conformance-claim.md) for the RFC-SA2A-007
  verifier, which is likewise not an A2A wire suite).
- **No cross-implementation interop testing** against other A2A v1.0
  servers/clients has been executed; the courts are self-conformance.

## See also

- [TCK suite](tck-suite.md) — how to run the in-repo conformance report
  and the official TCK, the court inventory, and witnessed verdicts.
- [A2A endpoint contract](a2a-endpoint-contract.md)
- [A2A spec version mapping](a2a-spec-version-mapping.md)
- [Conformance claim](conformance-claim.md)
- [Conformance profiles](conformance-profiles.md)
