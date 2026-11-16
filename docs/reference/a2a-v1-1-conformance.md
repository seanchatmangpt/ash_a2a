# A2A v1.1 Conformance Statement

Standing: PARTIAL (10 of 17 rows CONFORMANT, 7 PARTIAL, 0 GAP on the 2026-11-16 court run; no v1.1 TCK verdict exists)

Target: A2A v1.1.0 (upstream tag `v1.1.0-rc`; not yet a GitHub release). Corpus:
`priv/a2a_v1_1_spec_corpus/a2a.proto`, SHA-256
`8d9c363f8654205780654306af307355a7a34dcf96a8e221caf251268deab127`, byte-equal to upstream
`a2aproject/a2a` tag `v1.1.0-rc` `specification/a2a.proto` (see Evidence). A2A v1.0.1
remains supported ([v1.0 statement](a2a-v1-conformance.md)); v0.3 is decode-only
legacy.

The corpus court `test/ash_a2a_v1_1_proto_corpus_test.exs` checks the hash,
checks each delta item exists in the proto, and fails loudly on any item whose
codec status is still pending; it has zero `{:pending, _}` coverage entries. Court names are
`file::test`, with `test/` as the file root. The table has 17 rows and no row numbers.

Row standing rule: a row is CONFORMANT only when every court it names passed in the run
recorded under Evidence; otherwise it is PARTIAL and names the failing court. GAP would mean
no named court passed. CONFORMANT here means "the named courts pass", not a TCK verdict.

## Delta statement

Abbreviations: `codec` = `protocol_codec_v1_1_test.exs`, `corpus` =
`ash_a2a_v1_1_proto_corpus_test.exs`, `v2` = `task_generation_lifecycle_test.exs`.

| Item | Spec section | ash_a2a module | Court (file::test) | Standing |
|------|--------------|----------------|--------------------|----------|
| `SendLiveMessage` rpc (gRPC + `POST /message:live`) | spec 1.1 live streaming | `AshA2A.Transport.Live`, `AshA2A.Transport.HTTPJSON`, `AshA2A.Transport.GRPC.Server` | gRPC: `grpc_live_session_test.exs::SendLiveMessage subscribe-first: first frame is a Task snapshot`; HTTP+JSON: `http_json_live_session_test.exs::uplink by session id answers the ack task only...`, `http_json_generation_stream_test.exs::live downlink opens with the task snapshot...`; session: `live_session_streaming_test.exs::send_message opens with a snapshot, input_required, then a second message on the same stream`. JSON-RPC `SendLiveMessage` (specification section 5.3) is served by `AshA2A.Transport.Live.JSONRPC`; no court named here covers it | PARTIAL (failing: `http_json_live_session_test.exs::uplink by session id answers the ack task only`; `http_json_generation_stream_test.exs::live downlink opens with the task snapshot`) |
| `StreamRequest` | live streaming | `AshA2A.Protocol.JSON` | `codec::StreamRequest sendMessage / subscribe / unknown payload`; `v5::unknown payload kind and malformed requests are StreamErrors` | CONFORMANT |
| `StreamError` | live streaming | `AshA2A.Protocol.JSON.encode/1` | `codec::StreamError round trips through the StreamResponse wrapper`; `v5::request naming a different task is a StreamError and the stream stays open`; `grpc_live_session_test.exs::SendLiveMessage: wrong-task request yields StreamError and keeps the stream open` | CONFORMANT |
| `TimelineEntry` | ADR-002 | `AshA2A.Protocol.TimelineEntry`, `AshA2A.Protocol.JSON` | `codec::round trips generation and timeline entries`; `codec::timeline fails open on unknown entry kind`; `v2::artifacts leave generation gaps in the timeline and carry start/end generation` | PARTIAL (failing: `protocol_codec_v1_1_test.exs::round trips generation and timeline entries`; `protocol_codec_v1_1_test.exs::timeline fails open on unknown entry kind`) |
| `TaskMessageUpdateEvent` | ADR-002 | `AshA2A.Protocol.Event.MessageUpdate` | `codec::MessageUpdate round trips through the StreamResponse wrapper`; `http_json_generation_stream_test.exs::message:stream gives the client message to A2A-Version >= 1.1 only, in the snapshot timeline`; `sse_generation_frames_test.exs::1.0 stream: no messageUpdate frame and no error` | PARTIAL (failing: `http_json_generation_stream_test.exs::message:stream emits messageUpdate frames only for A2A-Version >= 1.1, all stamped`) |
| `Task.generation`, `Task.timeline` | ADR-002 | `AshA2A.Protocol.JSON` | `codec::round trips generation and timeline entries`; `v2::submitted -> working -> input_required -> working -> completed`; `grpc_live_session_test.exs::Task.generation survives the proto bridge` | PARTIAL (failing: `protocol_codec_v1_1_test.exs::round trips generation and timeline entries`) |
| `Artifact.startGeneration`, `endGeneration`, `role` | ADR-002 | `AshA2A.Protocol.JSON` | `codec::start/end generation and role round trip`; `codec::defaults omit the new members` | PARTIAL (failing: `protocol_codec_v1_1_test.exs::start/end generation and role round trip`) |
| `TaskStatusUpdateEvent.generation` | ADR-002 | `AshA2A.Protocol.JSON` | `codec::status and artifact updates carry generation`; `sse_generation_frames_test.exs::1.1 stream: statusUpdate and artifactUpdate carry strictly increasing generations` | PARTIAL (failing: `protocol_codec_v1_1_test.exs::status and artifact updates carry generation`) |
| `TaskArtifactUpdateEvent.generation` | ADR-002 | `AshA2A.Protocol.JSON` | `codec::status and artifact updates carry generation`; `sse_generation_frames_test.exs::1.1 stream: statusUpdate and artifactUpdate carry strictly increasing generations` | PARTIAL (failing: `protocol_codec_v1_1_test.exs::status and artifact updates carry generation`) |
| `SendMessageConfiguration.timelineLength`, `ifGenerationMatch` | ADR-002 | `AshA2A.Protocol.JSON`, agent state | `codec::configuration carries timelineLength, historyLength, ifGenerationMatch`; `generation_plug_wiring_test.exs::ifGenerationMatch mismatch answers -32010 with ErrorInfo through the plug`; `v12::build_call_opts forwards ifGenerationMatch so the agent's atomic check runs`; `v9::ifGenerationMatch: stale generation is 409 TASK_GENERATION_MISMATCH, matching generation succeeds` | CONFORMANT |
| `GetTaskRequest.timelineLength`, `currentGeneration` | ADR-002 | `AshA2A.Protocol.Agent.State` | `codec::GetTask / ListTasks / Subscribe v1.1 members`; `http_json_generation_stream_test.exs::currentGeneration at the task's generation parks until the task advances`; `client_live_transport_test.exs::get_task long-poll returns once the generation advances` | CONFORMANT |
| `ListTasksRequest.timelineLength` | ADR-002 | `AshA2A.Protocol.Agent.State` | `codec::GetTask / ListTasks / Subscribe v1.1 members`; `v9::timelineLength truncates GET /tasks/{id} and GET /tasks`; `v2::list truncation of timeline and history is independent` | CONFORMANT |
| `SubscribeToTaskRequest.lastSeenGeneration` | ADR-002 | `AshA2A.A2ATransport.Plug` | `v5::subscribe with lastSeenGeneration skips the snapshot; unreplayable generation resyncs`; `generation_gating_courts_test.exs::resubscribe with lastSeenGeneration == current sends no snapshot, only newer events`; `v13::invalid lastSeenGeneration answers -32602 before any stream opens`; `v10::SubscribeToTask lastSeenGeneration falls back to a snapshot when replay is unavailable` | CONFORMANT |
| `AgentCapabilities.userArtifacts` | client artifact writes | `AshA2A.Protocol.AgentCard`, `AshA2A.Protocol.JSON` | `codec::userArtifacts capability round trips`; `b3::card advertises capabilities.userArtifacts when declared and not when undeclared` | CONFORMANT |
| `SendMessageRequest.artifactUpdates` | client artifact writes | `AshA2A.Protocol.JSON` | `codec::message optional with artifactUpdates`; `v5::client artifactUpdates are applied and observable as artifact updates`; `v12::artifactUpdates on an agent without user_artifacts answers -32004`; `v10::artifactUpdates are accepted when user_artifacts is declared` | CONFORMANT |
| `TaskPushNotificationConfig.protocolVersion` | push notifications | `AshA2A.Protocol.JSON` | `codec::push config protocolVersion round trips and is optional`; `push_config_protocol_version_test.exs::set/get/list encode protocolVersion; explicit wins, default is the request version`; `push_config_protocol_version_test.exs::1.0 config gets no generation / message-update; 1.1 config gets both, in generation order` | CONFORMANT |
| `TaskGenerationMismatchError` -32010 | error registry | `AshA2A.Protocol.JSONRPC.Error` | `corpus::TaskGenerationMismatchError -32010 is registered in the corpus docs or spec text`; `v12::ifGenerationMatch mismatch answers -32010 with ErrorInfo through the plug`; `b3::ifGenerationMatch mismatch is -32010 TASK_GENERATION_MISMATCH; match proceeds`; `client_live_transport_test.exs::JSON-RPC -32010 maps to {:task_generation_mismatch, details}` | CONFORMANT |

## Evidence

Run: 2026-11-16, Elixir 1.20.4 / OTP 29.1.1, Postgres on `localhost:55432`. Commit
`25697513bbe3125f278458aea17982fa23ad6efa` (`git rev-parse HEAD`) with 48 uncommitted paths in the working tree (other
lanes were still editing `lib/` and `test/`), so the result binds to that tree, not to a
clean checkout of the commit. Each cited file was run on its own with `--trace`; a row's
courts were read from the per-test lines of that output.

| Item | Command | Result per file | Standing |
|------|---------|-----------------|----------|
| `SendLiveMessage` rpc (gRPC + `POST /message:live`) | `mix test test/grpc_live_session_test.exs test/http_json_live_session_test.exs test/http_json_generation_stream_test.exs test/live_session_streaming_test.exs --include serial --include serial_shard --include serial_solo --trace` | `grpc_live_session_test.exs` exit 0, 9 passed; `http_json_live_session_test.exs` exit 2, 3/4 passed; `http_json_generation_stream_test.exs` exit 2, 9/13 passed; `live_session_streaming_test.exs` exit 2, 15/16 passed | PARTIAL |
| `StreamRequest` | `mix test test/protocol_codec_v1_1_test.exs test/live_session_streaming_test.exs --include serial --include serial_shard --include serial_solo --trace` | `protocol_codec_v1_1_test.exs` exit 2, 18/22 passed; `live_session_streaming_test.exs` exit 2, 15/16 passed | CONFORMANT |
| `StreamError` | `mix test test/protocol_codec_v1_1_test.exs test/live_session_streaming_test.exs test/grpc_live_session_test.exs --include serial --include serial_shard --include serial_solo --trace` | `protocol_codec_v1_1_test.exs` exit 2, 18/22 passed; `live_session_streaming_test.exs` exit 2, 15/16 passed; `grpc_live_session_test.exs` exit 0, 9 passed | CONFORMANT |
| `TimelineEntry` | `mix test test/protocol_codec_v1_1_test.exs test/task_generation_lifecycle_test.exs --include serial --include serial_shard --include serial_solo --trace` | `protocol_codec_v1_1_test.exs` exit 2, 18/22 passed; `task_generation_lifecycle_test.exs` exit 0, 9 passed | PARTIAL |
| `TaskMessageUpdateEvent` | `mix test test/protocol_codec_v1_1_test.exs test/http_json_generation_stream_test.exs test/sse_generation_frames_test.exs --include serial --include serial_shard --include serial_solo --trace` | `protocol_codec_v1_1_test.exs` exit 2, 18/22 passed; `http_json_generation_stream_test.exs` exit 2, 9/13 passed; `sse_generation_frames_test.exs` exit 0, 4 passed | PARTIAL |
| `Task.generation`, `Task.timeline` | `mix test test/protocol_codec_v1_1_test.exs test/task_generation_lifecycle_test.exs test/grpc_live_session_test.exs --include serial --include serial_shard --include serial_solo --trace` | `protocol_codec_v1_1_test.exs` exit 2, 18/22 passed; `task_generation_lifecycle_test.exs` exit 0, 9 passed; `grpc_live_session_test.exs` exit 0, 9 passed | PARTIAL |
| `Artifact.startGeneration`, `endGeneration`, `role` | `mix test test/protocol_codec_v1_1_test.exs --include serial --include serial_shard --include serial_solo --trace` | `protocol_codec_v1_1_test.exs` exit 2, 18/22 passed | PARTIAL |
| `TaskStatusUpdateEvent.generation` | `mix test test/protocol_codec_v1_1_test.exs test/sse_generation_frames_test.exs --include serial --include serial_shard --include serial_solo --trace` | `protocol_codec_v1_1_test.exs` exit 2, 18/22 passed; `sse_generation_frames_test.exs` exit 0, 4 passed | PARTIAL |
| `TaskArtifactUpdateEvent.generation` | `mix test test/protocol_codec_v1_1_test.exs test/sse_generation_frames_test.exs --include serial --include serial_shard --include serial_solo --trace` | `protocol_codec_v1_1_test.exs` exit 2, 18/22 passed; `sse_generation_frames_test.exs` exit 0, 4 passed | PARTIAL |
| `SendMessageConfiguration.timelineLength`, `ifGenerationMatch` | `mix test test/protocol_codec_v1_1_test.exs test/generation_plug_wiring_test.exs test/http_json_generation_stream_test.exs --include serial --include serial_shard --include serial_solo --trace` | `protocol_codec_v1_1_test.exs` exit 2, 18/22 passed; `generation_plug_wiring_test.exs` exit 0, 5 passed; `http_json_generation_stream_test.exs` exit 2, 9/13 passed | CONFORMANT |
| `GetTaskRequest.timelineLength`, `currentGeneration` | `mix test test/protocol_codec_v1_1_test.exs test/http_json_generation_stream_test.exs test/client_live_transport_test.exs --include serial --include serial_shard --include serial_solo --trace` | `protocol_codec_v1_1_test.exs` exit 2, 18/22 passed; `http_json_generation_stream_test.exs` exit 2, 9/13 passed; `client_live_transport_test.exs` exit 0, 7 passed | CONFORMANT |
| `ListTasksRequest.timelineLength` | `mix test test/protocol_codec_v1_1_test.exs test/http_json_generation_stream_test.exs test/task_generation_lifecycle_test.exs --include serial --include serial_shard --include serial_solo --trace` | `protocol_codec_v1_1_test.exs` exit 2, 18/22 passed; `http_json_generation_stream_test.exs` exit 2, 9/13 passed; `task_generation_lifecycle_test.exs` exit 0, 9 passed | CONFORMANT |
| `SubscribeToTaskRequest.lastSeenGeneration` | `mix test test/live_session_streaming_test.exs test/generation_gating_courts_test.exs test/sse_generation_frames_test.exs test/grpc_live_session_test.exs --include serial --include serial_shard --include serial_solo --trace` | `live_session_streaming_test.exs` exit 2, 15/16 passed; `generation_gating_courts_test.exs` exit 0, 7 passed; `sse_generation_frames_test.exs` exit 0, 4 passed; `grpc_live_session_test.exs` exit 0, 9 passed | CONFORMANT |
| `AgentCapabilities.userArtifacts` | `mix test test/protocol_codec_v1_1_test.exs test/generation_gating_courts_test.exs --include serial --include serial_shard --include serial_solo --trace` | `protocol_codec_v1_1_test.exs` exit 2, 18/22 passed; `generation_gating_courts_test.exs` exit 0, 7 passed | CONFORMANT |
| `SendMessageRequest.artifactUpdates` | `mix test test/protocol_codec_v1_1_test.exs test/live_session_streaming_test.exs test/generation_plug_wiring_test.exs test/grpc_live_session_test.exs --include serial --include serial_shard --include serial_solo --trace` | `protocol_codec_v1_1_test.exs` exit 2, 18/22 passed; `live_session_streaming_test.exs` exit 2, 15/16 passed; `generation_plug_wiring_test.exs` exit 0, 5 passed; `grpc_live_session_test.exs` exit 0, 9 passed | CONFORMANT |
| `TaskPushNotificationConfig.protocolVersion` | `mix test test/protocol_codec_v1_1_test.exs test/push_config_protocol_version_test.exs --include serial --include serial_shard --include serial_solo --trace` | `protocol_codec_v1_1_test.exs` exit 2, 18/22 passed; `push_config_protocol_version_test.exs` exit 0, 3 passed | CONFORMANT |
| `TaskGenerationMismatchError` -32010 | `mix test test/ash_a2a_v1_1_proto_corpus_test.exs test/generation_plug_wiring_test.exs test/generation_gating_courts_test.exs test/client_live_transport_test.exs --include serial --include serial_shard --include serial_solo --trace` | `ash_a2a_v1_1_proto_corpus_test.exs` exit 0, 6 passed; `generation_plug_wiring_test.exs` exit 0, 5 passed; `generation_gating_courts_test.exs` exit 0, 7 passed; `client_live_transport_test.exs` exit 0, 7 passed | CONFORMANT |

Failing tests in the cited files in this run:

- `protocol_codec_v1_1_test.exs::Artifact start/end generation and role round trip`
- `protocol_codec_v1_1_test.exs::Task generation + timeline round trips generation and timeline entries`
- `protocol_codec_v1_1_test.exs::Task generation + timeline timeline fails open on unknown entry kind`
- `protocol_codec_v1_1_test.exs::events status and artifact updates carry generation`
- `http_json_live_session_test.exs::uplink by session id answers the ack task only; events arrive on the downlink`
- `http_json_generation_stream_test.exs::live downlink on an unknown task frames a StreamError and never a transport failure`
- `http_json_generation_stream_test.exs::live downlink opens with the task snapshot, then uplink events arrive on the downlink only`
- `http_json_generation_stream_test.exs::live downlink with an unknown payload kind frames UNKNOWN_PAYLOAD`
- `http_json_generation_stream_test.exs::message:stream emits messageUpdate frames only for A2A-Version >= 1.1, all stamped`
- `live_session_streaming_test.exs::artifactUpdates need user_artifacts`

These were observed while other lanes were still changing the live and codec paths. In the four
`protocol_codec_v1_1_test.exs` failures the encoder wrote `generation` (and
`startGeneration`) as a JSON string (`"7"`) where the court expects the integer `7`; the
HTTP+JSON live failures are an ack body wrapped in `{"task": ...}` and `StreamError` codes
(`INVALID_ARGUMENT`, `NOT_FOUND`) that differ from the ones the courts expect. This statement
does not decide whether the code or the court is right. Re-run the commands above when those
lanes land; the standings change only with that run.


- Corpus: `git -C <clone of a2aproject/a2a> show v1.1.0-rc:specification/a2a.proto | sha256sum`
  printed `8d9c363f8654205780654306af307355a7a34dcf96a8e221caf251268deab127`, the same as
  `sha256sum priv/a2a_v1_1_spec_corpus/a2a.proto` (tag commit `78e1d6a1f7f118c8e9bc830b04a8579c1119cb78`).
- `-32010` `TaskGenerationMismatchError` is in upstream `docs/specification.md` at that tag
  (line 1381: `-32010`, gRPC `ABORTED`, HTTP `409 Conflict`).
- `mix ash_a2a.sim --prove` on the same day: `221 probes over 83 surface items: 221 pass, 0 fail,
  0 skip`, in the `test` Mix environment and with `MIX_ENV=dev`. This is not row evidence.
- Court files not named in the table (`w1`, `w2`, `w3`, `w5`, `w6`) cover the v1.0
  surface and were not used as v1.1 evidence.
- Scope: the JSON-RPC binding defines no live method in the v1.1 proto; row 1 covers
  the two bindings that do (gRPC, HTTP+JSON).
- Earlier evidence (2026-11-13, commit `d8f593dc`, coordinator logs) is superseded by this
  run. See `docs/archive/jira-releases/v26.11.13/RECEIPT.md` (repository only; not in the Hex
  package).
- Table-level Standing is PARTIAL, not CONFORMANT: 7 row(s) have a failing court, and there is no v1.1 TCK verdict.

## Upstream comparison

Live upstream as summarized on 2026-11-13 (WebFetch): tags `v1.1.0-rc`
(2026-10-29), `v1.0.1` (2026-05-28); no v1.1.0 release exists. `main` proto is the
v1.0 surface (no `SendLiveMessage`, `StreamRequest`, `StreamError`,
`TimelineEntry`, `TaskMessageUpdateEvent`, `Task.timeline`, `Artifact.role`,
`user_artifacts`, `protocol_version`, `artifact_updates`). On 2026-11-16 the vendored corpus
was byte-compared with the `v1.1.0-rc` proto from a clone of the upstream repository and is
equal (see Evidence). See [known divergences](v1-1-known-divergences.md).

## External TCK

`a2aproject/a2a-tck` `main` is aligned to A2A 1.0.1. v1.1 requirements are not
yet in the TCK, so no TCK verdict exists for any row above. TCK certification
remains UNSUPPORTED (not claimed).

## See Also

- [A2A v1.1 readiness](a2a-v1_1-readiness.md)
- [Known divergences](v1-1-known-divergences.md)
- [Spec-version mapping](a2a-spec-version-mapping.md)
- [TCK suite](tck-suite.md)
