# A2A v1.1 Conformance Statement

Standing: PARTIAL

Target: A2A v1.1.0 (upstream tag `v1.1.0-rc`, fetched 2026-11-13; not yet a GitHub
release). Corpus: `priv/a2a_v1_1_spec_corpus/a2a.proto`, SHA-256
`8d9c363f8654205780654306af307355a7a34dcf96a8e221caf251268deab127`. A2A v1.0.1
remains supported ([v1.0 statement](a2a-v1-conformance.md)); v0.3 is decode-only
legacy.

The corpus court `test/ash_a2a_v1_1_proto_corpus_test.exs` checks the hash,
checks each delta item exists in the proto, and fails loudly on any item whose
codec status is still pending. Row standings below are set from the passing
courts named in each row (see Evidence). Court names are `file::test`, with
`test/` as the file root. The table has 17 rows and no row numbers; no row is
CONFORMANT without a named passing test.

## Delta statement

Abbreviations: `codec` = `protocol_codec_v1_1_test.exs`, `corpus` =
`ash_a2a_v1_1_proto_corpus_test.exs`, `v2` = `task_generation_lifecycle_test.exs`.

| Item | Spec section | ash_a2a module | Court (file::test) | Standing |
|------|--------------|----------------|--------------------|----------|
| `SendLiveMessage` rpc (gRPC + `POST /message:live`) | spec 1.1 live streaming | `AshA2A.Transport.Live`, `AshA2A.Transport.HTTPJSON`, `AshA2A.Transport.GRPC.Server` | gRPC: `grpc_live_session_test.exs::SendLiveMessage subscribe-first: first frame is a Task snapshot`; HTTP+JSON: `http_json_live_session_test.exs::uplink by session id answers the ack task only...`, `http_json_generation_stream_test.exs::live downlink opens with the task snapshot...`; session: `live_session_streaming_test.exs::send_message opens with a snapshot, input_required, then a second message on the same stream`. The proto defines SendLiveMessage only for gRPC and the HTTP binding (`post: "/message:live"`); the JSON-RPC binding has no live method, so none is implemented | CONFORMANT |
| `StreamRequest` | live streaming | `AshA2A.Protocol.JSON` | `codec::StreamRequest sendMessage / subscribe / unknown payload`; `v5::unknown payload kind and malformed requests are StreamErrors` | CONFORMANT |
| `StreamError` | live streaming | `AshA2A.Protocol.JSON.encode/1` | `codec::StreamError round trips through the StreamResponse wrapper`; `v5::request naming a different task is a StreamError and the stream stays open`; `grpc_live_session_test.exs::SendLiveMessage: wrong-task request yields StreamError and keeps the stream open` | CONFORMANT |
| `TimelineEntry` | ADR-002 | `AshA2A.Protocol.TimelineEntry`, `AshA2A.Protocol.JSON` | `codec::round trips generation and timeline entries`; `codec::timeline fails open on unknown entry kind`; `v2::artifacts leave generation gaps in the timeline and carry start/end generation` | CONFORMANT |
| `TaskMessageUpdateEvent` | ADR-002 | `AshA2A.Protocol.Event.MessageUpdate` | `codec::MessageUpdate round trips through the StreamResponse wrapper`; `http_json_generation_stream_test.exs::message:stream emits messageUpdate frames only for A2A-Version >= 1.1, all stamped`; `sse_generation_frames_test.exs::1.0 stream: no messageUpdate frame and no error` | CONFORMANT |
| `Task.generation`, `Task.timeline` | ADR-002 | `AshA2A.Protocol.JSON` | `codec::round trips generation and timeline entries`; `v2::submitted -> working -> input_required -> working -> completed`; `grpc_live_session_test.exs::Task.generation survives the proto bridge` | CONFORMANT |
| `Artifact.startGeneration`, `endGeneration`, `role` | ADR-002 | `AshA2A.Protocol.JSON` | `codec::start/end generation and role round trip`; `codec::defaults omit the new members` | CONFORMANT |
| `TaskStatusUpdateEvent.generation` | ADR-002 | `AshA2A.Protocol.JSON` | `codec::status and artifact updates carry generation`; `sse_generation_frames_test.exs::1.1 stream: statusUpdate and artifactUpdate carry strictly increasing generations` | CONFORMANT |
| `TaskArtifactUpdateEvent.generation` | ADR-002 | `AshA2A.Protocol.JSON` | `codec::status and artifact updates carry generation`; `sse_generation_frames_test.exs::1.1 stream: statusUpdate and artifactUpdate carry strictly increasing generations` | CONFORMANT |
| `SendMessageConfiguration.timelineLength`, `ifGenerationMatch` | ADR-002 | `AshA2A.Protocol.JSON`, agent state | `codec::configuration carries timelineLength, historyLength, ifGenerationMatch`; `generation_plug_wiring_test.exs::ifGenerationMatch mismatch answers -32010 with ErrorInfo through the plug`; `v12::build_call_opts forwards ifGenerationMatch so the agent's atomic check runs`; `v9::ifGenerationMatch: stale generation is 409 TASK_GENERATION_MISMATCH, matching generation succeeds` | CONFORMANT |
| `GetTaskRequest.timelineLength`, `currentGeneration` | ADR-002 | `AshA2A.Protocol.Agent.State` | `codec::GetTask / ListTasks / Subscribe v1.1 members`; `http_json_generation_stream_test.exs::currentGeneration at the task's generation parks until the task advances`; `client_live_transport_test.exs::get_task long-poll returns once the generation advances` | CONFORMANT |
| `ListTasksRequest.timelineLength` | ADR-002 | `AshA2A.Protocol.Agent.State` | `codec::GetTask / ListTasks / Subscribe v1.1 members`; `v9::timelineLength truncates GET /tasks/{id} and GET /tasks`; `v2::list truncation of timeline and history is independent` | CONFORMANT |
| `SubscribeToTaskRequest.lastSeenGeneration` | ADR-002 | `AshA2A.A2ATransport.Plug` | `v5::subscribe with lastSeenGeneration skips the snapshot; unreplayable generation resyncs`; `generation_gating_courts_test.exs::resubscribe with lastSeenGeneration == current sends no snapshot, only newer events`; `v13::invalid lastSeenGeneration answers -32602 before any stream opens`; `v10::SubscribeToTask lastSeenGeneration falls back to a snapshot when replay is unavailable` | CONFORMANT |
| `AgentCapabilities.userArtifacts` | client artifact writes | `AshA2A.Protocol.AgentCard`, `AshA2A.Protocol.JSON` | `codec::userArtifacts capability round trips`; `b3::card advertises capabilities.userArtifacts when declared and not when undeclared` | CONFORMANT |
| `SendMessageRequest.artifactUpdates` | client artifact writes | `AshA2A.Protocol.JSON` | `codec::message optional with artifactUpdates`; `v5::client artifactUpdates are applied and observable as artifact updates`; `v12::artifactUpdates on an agent without user_artifacts answers -32004`; `v10::artifactUpdates are accepted when user_artifacts is declared` | CONFORMANT |
| `TaskPushNotificationConfig.protocolVersion` | push notifications | `AshA2A.Protocol.JSON` | `codec::push config protocolVersion round trips and is optional`; `push_config_protocol_version_test.exs::set/get/list encode protocolVersion; explicit wins, default is the request version`; `push_config_protocol_version_test.exs::1.0 config gets no generation / message-update; 1.1 config gets both, in generation order` | CONFORMANT |
| `TaskGenerationMismatchError` -32010 | error registry | `AshA2A.Protocol.JSONRPC.Error` | `corpus::TaskGenerationMismatchError -32010 is registered in the corpus docs or spec text`; `v12::ifGenerationMatch mismatch answers -32010 with ErrorInfo through the plug`; `b3::ifGenerationMatch mismatch is -32010 TASK_GENERATION_MISMATCH; match proceeds`; `client_live_transport_test.exs::JSON-RPC -32010 maps to {:task_generation_mismatch, details}` | CONFORMANT |

## Evidence

Date: 2026-11-13. Evidence logs are coordinator-run; this lane ran no suites.

- `/tmp/coord-full-10.log` (default tier): `125 doctests, 51 properties, 4695
  tests, 0 failures, 4 skipped (1063 excluded)`, rc=0 per coordinator. The default
  tier excludes only `:external_api`, `:benchmark`, and environment-gated tags
  (`test/test_helper.exs`), so `:serial_shard` courts (`v9`, `v11_client_live`,
  `v14`, `b3_v11_courts`) are included. The log prints dots, not test names:
  each named court is covered by the aggregate 0-failure result plus its
  presence in `test/`, not by a per-test line.
- `/tmp/coord-serial.log` (`:serial` tier only): `11 doctests, 1038 tests, 40
  failures, 60 invalid, 8 skipped`. No failing or invalid entry names a v1.1
  court listed above. The failures read are in
  `AshA2A.Chicago.Hardening.AdversarialInputTest`
  (`{:invalid_field, "supportedInterfaces.protocolBinding"}`), and in
  Postgres-, sibling-dependency-, and wasm-gated modules. They are outside this
  statement and are not attributed to v1.1.
- Court files not named in the table (`w1`, `w2`, `w3`, `w5`, `w6`) cover the v1.0
  surface and were not used as v1.1 evidence.
- Scope: the JSON-RPC binding defines no live method in the v1.1 proto; row 1 covers
  the two bindings that do (gRPC, HTTP+JSON).
- Evidence binds to commit `d8f593dc` (default tier 4705 tests, 0 failures, twice;
  serial tier 0 failures). See `docs/archive/jira-releases/v26.11.13/RECEIPT.md`.
- Table-level Standing is PARTIAL (not CONFORMANT): all 17 rows are CONFORMANT by named
  courts without per-test log lines, and there is no v1.1 TCK verdict.

## Upstream comparison (2026-11-13)

Live upstream (WebFetch, summarized, not byte-compared): tags `v1.1.0-rc`
(2026-10-29), `v1.0.1` (2026-05-28); no v1.1.0 release exists. `main` proto is the
v1.0 surface (no `SendLiveMessage`, `StreamRequest`, `StreamError`,
`TimelineEntry`, `TaskMessageUpdateEvent`, `Task.timeline`, `Artifact.role`,
`user_artifacts`, `protocol_version`, `artifact_updates`). The `v1.1.0-rc` summary
lists the same v1.1 additions as the vendored corpus with matching field numbers
where stated; byte equality is UNVERIFIED. See
[known divergences](v1-1-known-divergences.md).

## External TCK

`a2aproject/a2a-tck` `main` is aligned to A2A 1.0.1. v1.1 requirements are not
yet in the TCK, so no TCK verdict exists for any row above. TCK certification
remains UNSUPPORTED (not claimed).

## See Also

- [A2A v1.1 readiness](a2a-v1_1-readiness.md)
- [Known divergences](v1-1-known-divergences.md)
- [Spec-version mapping](a2a-spec-version-mapping.md)
- [TCK suite](tck-suite.md)
