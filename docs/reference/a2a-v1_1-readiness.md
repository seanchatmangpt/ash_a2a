# A2A v1.1 Readiness Matrix

What the [a2a project roadmap](https://github.com/a2aproject/A2A) (vendored at
`~/ggen-marketplace/vendors/a2a/docs/roadmap.md`, last updated Sep 15 2026)
names as upcoming, and what `ash_a2a` actually has on disk today. Every
SUPPORTED/PARTIAL claim cites grep-verified code in this repository; a claim
without a citable module or court is stated as NOT-STARTED. This doc is the
next wave's backlog, not a marketing surface.

Secondary source: the MCP specification roadmap
(`~/ggen-marketplace/vendors/mcp-spec/docs/development/roadmap.mdx`,
2026-08-22) — cross-referenced where an MCP priority area has a direct A2A
analog ash_a2a already serves (see
[mcp-spec cross-reference](#mcp-spec-roadmap-cross-reference)).

Status vocabulary: `SUPPORTED` (landed, court cited), `PARTIAL` (what exists /
what is missing), `NOT-STARTED`, `NOT-APPLICABLE` (reason given). Version
reality: the wire protocol ash_a2a speaks is A2A **v1.0**
(`AshA2A.Protocol.Version.protocol_version/0` == `"1.0"`,
`lib/ash_a2a/protocol/version.ex`); "v1.1" items are upstream-in-flight and
triaged here against that v1.0 surface.

## Near-term initiatives

| Roadmap item (upstream ref) | Status | What exists / what is missing | Proof (module / court) |
| --- | --- | --- | --- |
| v1.1 core robustness — task timeline specifications (#1991) | PARTIAL | Landed (2026-10-05): the timeline projection exists — `AshA2A.Trace.export/3` folds the recorded saga (dispatch → authority → actuation → receipt, plus the task's wire event log) into an ordered, W3C-shaped span/event document; `AshA2A.Trace.Plug` serves it at `GET /tasks/{id}/trace` (`?format=otlp` for OTLP/JSON), owner-scoped (foreign/missing tasks answer identically, `-32001`). Missing: the v1.1 timeline *spec* is not final upstream — this is a TRACE/OTLP-aligned projection over the seq log, not the standardized v1.1 timeline wire format. | `lib/ash_a2a/trace.ex` (`AshA2A.Trace.export/3`), `lib/ash_a2a/trace/recorder.ex`, `lib/ash_a2a/trace/plug.ex`; substrate `lib/ash_a2a/a2a_transport/task_events.ex` (`publish/4`, `backlog/2`); courts `test/ash_a2a_trace_test.exs` (saga span tree, replay determinism, OTLP validity, owner scope), `test/ash_a2a/a2a_transport/resubscribe_test.exs` |
| v1.1 core robustness — standardized event filtering (backward-compatible) | PARTIAL | Exists: field filters on `tasks/list` (`context_id`, `status`, `status_timestamp_after`) and `historyLength` last-N truncation on `tasks/get`. Missing: any filter parameter on the *event streams* — `message/stream` and `tasks/resubscribe` replay is `Last-Event-ID` position only, no kind/state filter. | `lib/ash_a2a/protocol/task_store.ex:50-56`; `lib/ash_a2a/a2a_transport/sse.ex:249-250` (`last-event-id` only); conformance rows 6/8 in `docs/reference/a2a-v1-conformance.md` |
| v1.1 core robustness — messages received during working states (#1991) | PARTIAL | Exists: `continue_task/5` accepts any non-terminal state — a follow-up message on a `working` task is appended to history and re-runs the handler (input_required park/continue is court-pinned). Landed since the matrix draft: the BiDi input channel now provides a real concurrent client→agent path *while the handler is actively running* — mid-execution inputs are interleaved with output artifacts in order, court-pinned. Missing: the upstream guideline itself is not written (roadmap item is open); a plain `message/send` racing an actively-running handler (outside the BiDi channel) remains unpinned. | `lib/ash_a2a/protocol/agent/runtime.ex` (`continue_task/5`); BiDi `lib/ash_a2a/bidi.ex`; courts `test/ash_a2a_v1_bidi_test.exs` ((a) mid-stream inputs during active execution), `test/ash_a2a_v1_conformance_test.exs` row 5 |
| BiDi streaming (#1995) — real-time artifact updates | SUPPORTED | Server→client: `message/stream` through a supervised pump, one `TaskArtifactUpdateEvent` per part, multi-subscriber fan-out, `Last-Event-ID` replay, keepalive, disconnect never halts the task. | `lib/ash_a2a/a2a_transport/sse.ex` (moduledoc + `stream_message/7`), `lib/ash_a2a/a2a_transport/task_events.ex`; courts `test/ash_a2a_sse_stream_test.exs`, `test/ash_a2a_v1_sse_replay_test.exs`, `test/ash_a2a_v1_artifact_streaming_test.exs` |
| BiDi streaming (#1995) — continuous multi-turn messaging while executing | SUPPORTED | Landed (2026-10-05): a real concurrent client→agent path while a task executes. The skill opens a per-task input channel (`AshA2A.Bidi.open/2`, Registry + `DynamicSupervisor`); `AshA2A.Bidi.Stream` turns it into a lazy input stream the running skill pulls (consumer-driven, in-order). Wire surface: `POST <mount>/bidi/<task_id>/input` and `/bidi/<task_id>/close` as JSON-RPC envelopes on the same SSE transport; explicit close finalizes, consumer death fails the task, late/unknown input is a typed refusal (`-32001` for unknown task). | `lib/ash_a2a/bidi.ex` (`AshA2A.Bidi`), `lib/ash_a2a/bidi/{channel,stream,plug}.ex`; court `test/ash_a2a_v1_bidi_test.exs` ((a) three mid-stream inputs interleaved in order, close finalizes `COMPLETED`, late input refused; (b) `-32001` unknown task; (c) buffer/eof/late-delivery; (d) typed `not_found` for a channel that never opened) |
| BiDi streaming (#1995) — role management | NOT-STARTED | No matches for role management beyond the static `role` field on `Message` (`ROLE_USER`/`ROLE_AGENT` wire enum). | `lib/ash_a2a/protocol/message.ex` |
| A2A CLI + coding-harness integration (#1929) | NOT-APPLICABLE | Upstream client-side tool (`a2aproject/a2a-cli`); ash_a2a is a server SDK. ash_a2a's corresponding client surface is `AshA2A.Protocol.Client` (discover, send, stream, resubscribe) — unverified against the CLI; the backlog item is a CLI-interop court, not a CLI. | `lib/ash_a2a/protocol/client.ex` (`discover/2`, `send_message/3`, `stream_message/3`, `resubscribe/3`) |
| Elicitation & multi-turn (#2149, #2143) — structured human-in-the-loop | SUPPORTED | Landed (2026-10-05): the formal elicitation contract — a typed, schema-constrained input request over the A2A `INPUT_REQUIRED` park/resume lifecycle. `request/3` mints an elicitation carrying the real Draft 2020-12 `requestedSchema` projected from `AshA2A.Schema.for_action/3`/`for_skill/2`, riding as a `Part.Data` part on the `{:input_required, _}` reply; `resume/2` validates the follow-up **before** dispatch resumes — any violation is a typed `-32602` and the task stays parked (a malformed response must not consume the park); expiry (`:expires_in`) transitions a parked task to terminal `:failed`. Scope note: it covers the MCP `elicitation/create` *form mode* subset (flat primitives/enum/arrays), not the full #2149 exploration surface. | `lib/ash_a2a/elicitation.ex` (`request/3`, `resume/2`, `validate/2`); court `test/ash_a2a_v1_elicitation_test.exs` (wrong-shape refused + stays parked + correct shape resumes to `COMPLETED`; uncorrelated follow-up `-32602`; expiry → `FAILED`; default never-expiry; `validate/2` fail-closed subset; real schema projection) |
| Elicitation & multi-turn (#2143) — multi-round negotiation | PARTIAL | Multi-round on the same task works (park → continue → complete; context/history continuity court-pinned across turns). Negotiation patterns per #2143 (telecom-informed) have no implementation. | Conformance rows 5, 17, 18 (`test/ash_a2a_v1_conformance_test.exs`, `test/ash_a2a_v1_context_continuity_test.exs`) |
| Extensions | PARTIAL | Exists: the full declaration/negotiation pipeline — card `capabilities.extensions`, `A2A-Extensions` request parse + activated-URI response echo, required-extension refusal `-32008`, `activate/3`/`handle_request/3`/`handle_response/3` hooks, client-side header send, in-tree timestamp reference extension. Missing: method extensions (new RPC methods) and state-machine extensions — explicitly "not yet supported" in the module doc. | `lib/ash_a2a/protocol/extension.ex`, `lib/ash_a2a/protocol/agent_extension.ex`, `lib/ash_a2a/protocol/plug.ex:327,431`, `lib/ash_a2a/protocol/client.ex:44,164`, `lib/ash_a2a/protocol/extension/timestamp.ex`; court `test/ash_a2a_protocol_extension_e2e_test.exs` (+ fixture `test/support/protocol_extension_e2e_fixture.ex`) |
| Validation (A2A Inspector, TCK) | PARTIAL | Exists: in-repo TCK-closure court for the HTTP+JSON binding over a real Bandit server (no mocks), a v2.1.0-ontology conformance court, a per-requirement v1.0 conformance statement with executed courts, and the **official `a2aproject/a2a-tck` compatibility suite run to a green verdict** — 2026-10-05 post-hardening run (`/tmp/a2a-tck/reports/compatibility.json`, 23:17:14Z): **0 test failures on every transport that ran** (agent_card 10/10, jsonrpc 81/81 run with 0 fail, http_json 77/77 run with 0 fail), overall 76.0% (MUST 76.4%, SHOULD 63.6%, MAY 100%); the residue to 100% is entirely not-run surface (gRPC skipped — card declares JSONRPC only; push skipped — card advertises `pushNotifications: false`; 25 NOT TESTED = signed-card / TLS / auth-server setups). Still missing: Inspector remains unverified; TCK has not been run over gRPC; the verdict is point-in-time — certification is explicitly not claimed; TCK-in-CI is a documented refusal (`REFUSED(ci:tck-not-in-tree)`, `.github/workflows/ci.yml`). | `test/ash_a2a_v1_httpjson_tck_closures_test.exs` ("Lane G-P court"), `test/ash_a2a/a2a_protocol_v2_1_0_conformance_test.exs`, `docs/reference/a2a-v1-conformance.md` ("A2A TCK compatibility run" section — remaining-gap table) |
| SDKs (six hosted languages) | NOT-APPLICABLE | ash_a2a is a community (non-hosted) Elixir SDK — the roadmap item concerns upstream hosting; ash_a2a *is* the community Elixir contribution. Related on-ramp documented for users of the hex `a2a` package. | `docs/how-to/migrate-from-a2a-hex.md` |
| Community best practices | NOT-APPLICABLE | Documentation/community participation, not code. | n/a |

## TCK cross-reference

The roadmap announces no per-item TCK suites: the Technology Compatibility
Kit is linked generally under the Validation section
([a2a-tck](https://github.com/a2aproject/a2a-tck)), and community SDKs run it
as a CI conformance badge (e.g. a2a-cpp in `vendors/a2a/docs/community.md:105`).
Honest mapping, per item:

| Roadmap item | TCK suite announced? | ash_a2a in-repo substitute |
| --- | --- | --- |
| v1.1 task timeline / event filtering / working-state messages | No — v1.1 spec not final; TCK tracks released spec versions | Timeline: `AshA2A.Trace` projection + `GET /tasks/{id}/trace` court (`test/ash_a2a_trace_test.exs`); filtering: pinned row-6/8 conformance rows; working-state messages: row-5 court + the BiDi mid-execution input court |
| BiDi streaming | No — no TCK suite announced for BiDi in the roadmap | Both halves now covered in-repo: SSE courts (replay, artifact streaming) for server→client, `test/ash_a2a_v1_bidi_test.exs` for client→server inputs |
| A2A CLI | No — CLI has its own repo, no TCK suite announced | None (NOT-APPLICABLE row above) |
| Elicitation / multi-turn | No — #2149 is a PR under exploration | Row 5 / context-continuity courts cover the input_required flow; the structured elicitation contract is court-pinned (`test/ash_a2a_v1_elicitation_test.exs`) |
| Extensions | No — extensions are validated per-extension-spec, not by core TCK | `test/ash_a2a_protocol_extension_e2e_test.exs` |
| Base protocol v1.0 (implicit) | Yes — the TCK's core suites exist for v1.0 (community SDKs badge it) | `test/ash_a2a_v1_httpjson_tck_closures_test.exs` + `docs/reference/a2a-v1-conformance.md` (v1.0.0 per-requirement courts) |

## mcp-spec roadmap cross-reference

Directional only — ash_a2a is an A2A library, not an MCP implementation. Rows
name where an MCP roadmap priority area has an A2A analog ash_a2a already
serves, so the next wave can decide relevance, not import MCP semantics
blindly.

| MCP priority area (roadmap.mdx, 2026-08-22) | A2A analog in ash_a2a | Status |
| --- | --- | --- |
| 1. Agentic messaging — server-initiated events / webhooks | Push-notification delivery: config store, webhook policy, push delivery per status-bearing event | SUPPORTED — `lib/ash_a2a/a2a_transport/push_delivery.ex`, `push_config_store.ex`, `push_config_rpc.ex`, `webhook_policy.ex`; courts `test/ash_a2a/a2a_transport/push_notification_test.exs`, `webhook_policy_test.exs` |
| 1. Agentic messaging — Tasks extension composition (SEP-2663) | A2A task model is native (`AshA2A.Protocol.Task`, state machine `lib/ash_a2a/task_lifecycle.ex`); MCP Tasks semantics are N/A | NOT-APPLICABLE — different protocol's concept; A2A tasks already land |
| 3. Agent identity — DPoP / workload identity / token exchange | AuthZEN access-evaluation client observing PDP decisions as evidence; OAuth bearer surface on the plugs; **Agent Passport landed post-matrix** (`lib/ash_a2a/passport.ex` + `{merkle,revocation,plug}.ex`: Merkle-rooted, JWS-signed portable identity doc with fail-closed verify/revocation; court `test/ash_a2a_passport_test.exs`, 31/0). DPoP: zero hits in the tree. | PARTIAL — `lib/ash_a2a/authzen/client.ex` (`evaluate/2`; "an allow confers no authority"), `lib/ash_a2a/authzen/` (8 modules); DPoP NOT-STARTED |
| 2. HTTP-native transport / 4. primitives / 5. SDK DX | N/A — MCP-internal concerns with no A2A-side counterpart | NOT-APPLICABLE |

## Security posture (post-hardening, 2026-10-05)

Landed gates (commit `059ff0e3`):

- **Static analysis: sobelow is now a CI gate.** A `security` job in
  `.github/workflows/ci.yml` runs `mix sobelow --exit high`
  (MIX_ENV=dev, SHA-pinned actions, least-privilege permissions,
  15-minute timeout). hex.audit was already gated (supply-chain job in
  `ci.yml` + `release.yml`); it is not duplicated.
- **Dispositions from the local re-run** at `059ff0e3`
  (`MIX_ENV=dev mix sobelow --exit high`, 2026-10-05): 11
  high-confidence findings — 1 `Config.HTTPS` (HTTPS not enabled,
  `config/prod.exs`) and 10 `Misc.BinToTerm` (unsafe
  `binary_to_term`) across
  `lib/ash_a2a/beam_file.ex`,
  `lib/ash_a2a/chicago/fixtures/{chaos_reconciliation,receipt_binding_attestation}.ex`,
  `lib/ash_a2a/consequence_kernel/effect_claim_store/durable_file.ex`,
  `lib/ash_a2a/consequence_kernel/prepared_effect_store/journal.ex`,
  `lib/ash_a2a/consequence_kernel/w5/effect_claim_store/file.ex`,
  `lib/ash_a2a/execution_snapshot.ex`,
  `lib/ash_a2a/receipt/evidence_chain.ex`,
  `lib/ash_a2a/receipt_outbox.ex`; plus 343 low-confidence findings
  (predominantly `Traversal.FileModule` on the file-backed
  receipt/journal/fixture paths). **The `--exit high` CI gate will
  fail on this surface until the 11 high-confidence findings are
  fixed or explicitly `# sobelow-ignore`-dispositioned** — that is
  the top remaining security work, not a green claim.

## What is not claimed

- No claim that ash_a2a passes the upstream `a2a-tck`; the in-repo TCK-closure
  court is a substitute, not the suite (the compatibility suite itself has run
  green — see the Validation row and
  [a2a-v1-conformance.md](a2a-v1-conformance.md)).
  landed after this matrix was first drafted; `lib/ash_a2a/passport.ex`,
  `lib/ash_a2a/passport/{merkle,revocation,plug}.ex`, and
  `test/ash_a2a_passport_test.exs` (31 courts) all verified on disk — the
  identity row above already cites the Passport surface (triage complete,
  2026-10-05).
- Statuses reflect the tree as read on 2026-10-05 (full re-triage pass); this
  is a live doc — a row whose citation stops matching the code is stale and
  should be re-triaged.
