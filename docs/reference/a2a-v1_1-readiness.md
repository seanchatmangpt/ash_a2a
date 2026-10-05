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
| v1.1 core robustness — task timeline specifications (#1991) | NOT-STARTED | No `timeline` anywhere under `lib/` or `test/`. Nearest existing substrate: the per-task monotonic, sequence-numbered event log with bounded retention (`seq`, final-event sweep) — a timeline is a projection over exactly this log. | `lib/ash_a2a/a2a_transport/task_events.ex` (`publish/5`, `backlog/2`); court `test/ash_a2a/a2a_transport/resubscribe_test.exs` |
| v1.1 core robustness — standardized event filtering (backward-compatible) | PARTIAL | Exists: field filters on `tasks/list` (`context_id`, `status`, `status_timestamp_after`) and `historyLength` last-N truncation on `tasks/get`. Missing: any filter parameter on the *event streams* — `message/stream` and `tasks/resubscribe` replay is `Last-Event-ID` position only, no kind/state filter. | `lib/ash_a2a/protocol/task_store.ex:50-56`; `lib/ash_a2a/a2a_transport/sse.ex:249-250` (`last-event-id` only); conformance rows 6/8 in `docs/reference/a2a-v1-conformance.md` |
| v1.1 core robustness — messages received during working states (#1991) | PARTIAL | Exists: `continue_task/5` accepts any non-terminal state — a follow-up message on a `working` task is appended to history and re-runs the handler (input_required park/continue is court-pinned). Missing: the upstream guideline itself is not written (roadmap item is open); ash_a2a's own behavior on a message arriving while the handler is *actively running* is unpinned — no court exercises that race today. | `lib/ash_a2a/protocol/agent/runtime.ex` (`continue_task/5`, "Valid for any non-terminal task state"); `lib/ash_a2a/protocol/agent.ex:58-70`; court `test/ash_a2a_v1_conformance_test.exs` row 5 |
| BiDi streaming (#1995) — real-time artifact updates | SUPPORTED | Server→client: `message/stream` through a supervised pump, one `TaskArtifactUpdateEvent` per part, multi-subscriber fan-out, `Last-Event-ID` replay, keepalive, disconnect never halts the task. | `lib/ash_a2a/a2a_transport/sse.ex` (moduledoc + `stream_message/7`), `lib/ash_a2a/a2a_transport/task_events.ex`; courts `test/ash_a2a_sse_stream_test.exs`, `test/ash_a2a_v1_sse_replay_test.exs`, `test/ash_a2a_v1_artifact_streaming_test.exs` |
| BiDi streaming (#1995) — continuous multi-turn messaging while executing | NOT-STARTED | No inbound-message channel while a task is executing: `continue_task/5` is a serialized GenServer `call`; there is no concurrent client→agent path. The only `bidi` grep hit in the tree is an unrelated `bidirectional?` content-digest compat flag. | `lib/ash_a2a/protocol/agent/runtime.ex` (`continue_task/5`); `lib/ash_a2a/semantic/revision.ex:144-153` (the unrelated hit, cited so the next wave does not mistake it for BiDi) |
| BiDi streaming (#1995) — role management | NOT-STARTED | No matches for role management beyond the static `role` field on `Message` (`ROLE_USER`/`ROLE_AGENT` wire enum). | `lib/ash_a2a/protocol/message.ex` |
| A2A CLI + coding-harness integration (#1929) | NOT-APPLICABLE | Upstream client-side tool (`a2aproject/a2a-cli`); ash_a2a is a server SDK. ash_a2a's corresponding client surface is `AshA2A.Protocol.Client` (discover, send, stream, resubscribe) — unverified against the CLI; the backlog item is a CLI-interop court, not a CLI. | `lib/ash_a2a/protocol/client.ex` (`discover/2`, `send_message/3`, `stream_message/3`, `resubscribe/3`) |
| Elicitation & multi-turn (#2149, #2143) — structured human-in-the-loop | NOT-STARTED | Zero hits for "elicitation" in `lib/`, `test/`, `docs/`. The existing HITL-shaped mechanism is the v1.0 `input_required` park/continue flow — synchronous, court-pinned, but not the structured elicitation model #2149 explores. | `lib/ash_a2a/protocol/agent.ex:58-70,123-129`; court row 5 of `docs/reference/a2a-v1-conformance.md` |
| Elicitation & multi-turn (#2143) — multi-round negotiation | PARTIAL | Multi-round on the same task works (park → continue → complete; context/history continuity court-pinned across turns). Negotiation patterns per #2143 (telecom-informed) have no implementation. | Conformance rows 5, 17, 18 (`test/ash_a2a_v1_conformance_test.exs`, `test/ash_a2a_v1_context_continuity_test.exs`) |
| Extensions | PARTIAL | Exists: the full declaration/negotiation pipeline — card `capabilities.extensions`, `A2A-Extensions` request parse + activated-URI response echo, required-extension refusal `-32008`, `activate/3`/`handle_request/3`/`handle_response/3` hooks, client-side header send, in-tree timestamp reference extension. Missing: method extensions (new RPC methods) and state-machine extensions — explicitly "not yet supported" in the module doc. | `lib/ash_a2a/protocol/extension.ex`, `lib/ash_a2a/protocol/agent_extension.ex`, `lib/ash_a2a/protocol/plug.ex:327,431`, `lib/ash_a2a/protocol/client.ex:44,164`, `lib/ash_a2a/protocol/extension/timestamp.ex`; court `test/ash_a2a_protocol_extension_e2e_test.exs` (+ fixture `test/support/protocol_extension_e2e_fixture.ex`) |
| Validation (A2A Inspector, TCK) | PARTIAL | Exists: in-repo TCK-closure court for the HTTP+JSON binding over a real Bandit server (no mocks), a v2.1.0-ontology conformance court, and a per-requirement v1.0 conformance statement with executed courts. Missing: an actual run of the upstream `a2a-tck` suite against ash_a2a; Inspector unverified. | `test/ash_a2a_v1_httpjson_tck_closures_test.exs` ("Lane G-P court"), `test/ash_a2a/a2a_protocol_v2_1_0_conformance_test.exs`, `docs/reference/a2a-v1-conformance.md` |
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
| v1.1 task timeline / event filtering / working-state messages | No — v1.1 spec not final; TCK tracks released spec versions | None; only the seq-log substrate (`task_events.ex`) and pinned row-5/row-12 conformance courts |
| BiDi streaming | No — no TCK suite announced for BiDi in the roadmap | SSE courts (replay, artifact streaming) cover the server→client half only |
| A2A CLI | No — CLI has its own repo, no TCK suite announced | None (NOT-APPLICABLE row above) |
| Elicitation / multi-turn | No — #2149 is a PR under exploration | Row 5 / context-continuity courts cover the input_required flow |
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

## What is not claimed

- No claim that ash_a2a passes the upstream `a2a-tck`; the in-repo TCK-closure
  court is a substitute, not the suite.
- `lib/ash_a2a/passport/` (Agent Passport, Merkle + JWS identity document)
  landed after this matrix was drafted; see `lib/ash_a2a/passport.ex`,
  `lib/ash_a2a/passport/{merkle,revocation,plug}.ex`, and
  `test/ash_a2a_passport_test.exs` (31 courts). The identity row above
  predates it — triage it against the Passport surface on the next pass.
- Statuses reflect the tree as read on 2026-10-04; this is a live doc — a row
  whose citation stops matching the code is stale and should be re-triaged.
