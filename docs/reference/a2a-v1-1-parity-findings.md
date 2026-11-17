# A2A v1.1 parity findings

Findings of the parity check (`mix ash_a2a.sim --parity`,
[how to run it](../how-to/check-a2a-v1-1-parity.md)) against the upstream
specification at tag `v1.1.0-rc`. Section numbers refer to
`docs/specification.md` at that tag.

No finding is open: `mix ash_a2a.sim --parity --strict` exits `0` and
`scripts/a2a_v1_1_parity/known_defects.json` is empty. This page records what
the check found, what the wire carries now, and which protocol versions each
rule applies to.

## Closed findings

| Id | Defect | Fix |
| --- | --- | --- |
| F-01 | gRPC answered `UNIMPLEMENTED` for `UnsupportedOperationError` and `VersionNotSupportedError` | `FAILED_PRECONDITION` (5.4), in `lib/ash_a2a/transport/grpc` |
| F-02 | gRPC streaming RPCs lost the `ErrorInfo` and answered a stale `ifGenerationMatch` with `FAILED_PRECONDITION` | `NOT_FOUND`/`ABORTED` with `ErrorInfo` (10.6), in `lib/ash_a2a/transport/grpc` |
| F-03 | gRPC `SubscribeToTask` events carried generation 0 | each event carries the task's generation (3.2.7) |
| F-04 | stream generations disagreed with the stored task | every streamed chunk is a stored mutation (`{:stream_chunk, ...}` from `AshA2A.Protocol.Agent.Runtime.wrap_stream/4`); its `artifactUpdate` carries the generation `GetTask` then reports, on all three bindings (3.2.7) |
| F-05 | `SubscribeToTask` skipped the artifact mutation | subscribe streams derive one event per mutation from the stored task (`AshA2A.Protocol.Task.Delta`): the `artifactUpdate` is delivered, no generation gap; `/jsonrpc` resumes reach the terminal status |
| F-06 | `SendLiveMessage` skipped the working status on the downlink | every status the timeline recorded since the last observation is its own `statusUpdate` (`AshA2A.Transport.Live.Session`) |
| F-07 | streaming a message whose task interrupts was refused; a stale `ifGenerationMatch` on a stream answered `-32004` | the stream opens with the `Task`; the mismatch is `-32010` (`AshA2A.A2ATransport.SSE`, `AshA2A.A2ATransport.Plug`, gRPC server) |
| F-08 | a task that finished after the call returned sent no push notification | `AshA2A.A2ATransport.DetachedWatch` follows a task answered while running and publishes its later states |
| F-09 | 401 and 403 bodies were not in the binding's error format | `AshA2A.Protocol.Plug.Auth` option `:error_format` (`:http_json`, `:jsonrpc`; default `:plain` is unchanged) |
| F-10 | the JSON-RPC binding had no `SendLiveMessage` | `AshA2A.Transport.Live.JSONRPC`, served by both JSON-RPC mounts (5.3) |
| F-11 | the `/jsonrpc` mount replayed a client message after the snapshot and answered a version refusal with `id: null` | no replay; the refusal carries the request id (`AshA2A.Transport.Plug`) |
| F-12 | the final chunk of a streamed artifact could go out without `lastChunk` (it was stored before the stream was known to have ended, and the flag was never sent afterwards) | the stream wrapper stores a chunk when its successor arrives or the stream ends, so the final chunk is stored as the one that completes the artifact; every event derived from the stored task carries `lastChunk: true` on it and on no other (`AshA2A.Protocol.Agent.Runtime.wrap_stream/4`). Vector `lastChunk on the final chunk of each artifact only` |
| F-13 | (question, no defect at this revision) must a stream carry `TASK_STATE_WORKING`? | yes when it happened after the opening `Task`: `a2a.proto` `TimelineEntry.status` is "Streamed via `TaskStatusUpdateEvent`" and 3.2.7 allows no generation gap. The task store records working as its own generation and `AshA2A.Protocol.Task.Delta` emits it; a stream whose opening `Task` is already working has nothing to add. Vector `every recorded status is a statusUpdate` |
| G-01 | an undecodable gRPC request message answered `UNKNOWN` (`grpc_server` decodes before any interceptor or service function and turns the raise into `UNKNOWN`) | `INVALID_ARGUMENT` with `ErrorInfo{INVALID_PARAMS}`: the server's own request codecs (`AshA2A.Transport.GRPC.Codec`, given to `use GRPC.Server, codecs:`) hand the RPC a marker instead of raising; on `SendLiveMessage` the bad `StreamRequest` is a `StreamError` and the stream stays open |
| G-02 | an RPC the service does not have answered a bare HTTP/2 `404` (`GRPC.Server.Adapters.Cowboy.Router`) | HTTP `200`, Trailers-Only `grpc-status: 12` (`UNIMPLEMENTED`): `AshA2A.Transport.GRPC.Supervisor` appends `AshA2A.Transport.GRPC.UnknownMethod` as the last route of the listener it starts. A host that starts the endpoint itself (not through that supervisor) calls `AshA2A.Transport.GRPC.UnknownMethod.install/1` after `GRPC.Server.start_endpoint/3`, or keeps the adapter's 404 |

F-07's JSON-RPC half touched `lib/ash_a2a/a2a_transport/sse.ex` and
`plug.ex`, a few lines each.

## Which versions each wire rule applies to

A request names its version in `A2A-Version`. The `v1.0` rows of the matrix
send `1.0` and parse every answer strictly with stubs generated from
`specification/a2a.proto` at tag `v1.0.1`, so a v1.1-only member on a v1.0
answer fails. Section numbers in this table refer to the specification at
`v1.0.1`.

| Rule | v1.0 too? | Basis | Gate |
| --- | --- | --- | --- |
| int64 as a decimal string | not reachable | v1.0.1 has no int64 field; `generation`, `startGeneration`, `endGeneration` are v1.1 | those members are dropped for a v1.0 request (`AshA2A.Protocol.Downgrade`) |
| Timestamp with 0, 3 or 6 fractional digits | yes | ProtoJSON (ADR-001, 5.6.1) | none |
| Default values omitted (`append`, `lastChunk`, empty `configs`, empty `nextPageToken`) | yes | ProtoJSON; none of these is `REQUIRED` in the v1.0.1 proto | none |
| Integral double read as an integer in a data part | yes | `Part.data` is `google.protobuf.Value` in both | none |
| v1 push-config request shapes, `{}` for a delete | yes | the v1.0.1 request messages are the same | none |
| Unknown push config is `TaskNotFoundError` | yes | 3.1.8 | none |
| `error.data` / `error.details` is an array of typed objects | yes | 9.5, 11.6 | none |
| HTTP 400 / 400 / 500 for `TaskNotCancelable`, `ContentTypeNotSupported`, `InvalidAgentResponse` | yes | 5.4 has the same table | none |
| `taskPushNotificationConfig` in `SendMessageConfiguration` | yes | the v1.0.1 proto names the field `task_push_notification_config` | none; `pushNotificationConfig` is still read |
| `TaskPushNotificationConfig.protocolVersion` | no | field 7 is new in v1.1 | dropped for a v1.0 request (`PushConfigRPC`); the check found it leaking |
| `messageUpdate` frames, `timeline`, `StreamError`, `SendLiveMessage` | no | v1.1 only | `messageUpdate` and the v1.1 members are withheld below 1.1; `SendLiveMessage` is a v1.1 operation |

## Wire shape fixes

Found by the first run of the check and fixed in the library.

| Defect | Was | Now | Where |
| --- | --- | --- | --- |
| int64 fields as JSON numbers | `"generation": 5`, `"startGeneration": 4` | `"generation": "5"` (ProtoJSON, ADR-001) | `AshA2A.Protocol.JSON`, `AshA2A.A2ATransport.TaskEvents` |
| Timestamp fraction followed the struct precision | `…:40.250000Z` | 0, 3 or 6 digits by value: `…:40.250Z` | `AshA2A.Protocol.JSON` |
| Default-valued members emitted | `"append": false`, `"lastChunk": false`; `"configs": []`, `"nextPageToken": ""` in `ListTaskPushNotificationConfigsResponse` | omitted | `AshA2A.Protocol.JSON`, `PushConfigRPC`, `HTTPJSON`, `JSONRPC` |
| Integral doubles refused over JSON | a ProtoJSON client's `{"delay_ms": 900.0}` failed the skill; gRPC accepted it | read as `900` | `AshA2A.Protocol.JSON` (data part decode) |
| Empty `metadata` on `/a2a` tasks | `"metadata": {}` over JSON-RPC, absent elsewhere | absent | `AshA2A.A2ATransport.Ownership` |
| v1 push-config requests over JSON-RPC | `GetTaskPushNotificationConfig {taskId, id}` answered `-32001`; `List…` answered the 0.3 nested shape; `Delete…` answered `-32602` | answered in the v1 shape | `PushConfigRPC` |
| Unknown push config | `-32602` / `INVALID_ARGUMENT` | `TaskNotFoundError` (3.1.8) | `PushConfigRPC` |
| JSON-RPC delete result | `"result": null` | `"result": {}` (`google.protobuf.Empty`) | `PushConfigRPC` |
| `error.data` on `-32600`, `-32601`, `-32700` | a string | an array holding a `google.rpc.ErrorInfo` (9.5) | `AshA2A.Protocol.JSONRPC.Error` |
| HTTP status of A2A errors | `TaskNotCancelable` 409, `ContentTypeNotSupported` 415, `InvalidAgentResponse` 502 | 400, 400, 500 (5.4) | `HTTPJSON` |
| Extended card capabilities | `extendedAgentCard: false`, `pushNotifications: false` on the card `GetExtendedAgentCard` answers | the served capabilities | `ExtendedCard`, `HTTPJSON`, `A2ATransport.Plug` |
| `/message:stream` replayed client messages | `task` at generation 3, then `messageUpdate` at 2 | no replay after the snapshot | `HTTPJSON` |
| `/message:live` uplink acknowledgement | a bare `Task` | `{"task": {...}}`, a `StreamResponse` | `HTTPJSON` |
| `StreamError.code` values | `TASK_NOT_FOUND`, `UNSUPPORTED_OPERATION`, `UNKNOWN_PAYLOAD` | `NOT_FOUND`, `FAILED_PRECONDITION`, `INVALID_ARGUMENT` (the unary operation's codes) | `HTTPJSON`, `Live.Session` |
| Inline push config member | only `pushNotificationConfig` (1.0) was read | `taskPushNotificationConfig` (1.1) too | `HTTPJSON`, `A2ATransport.Plug` |
| Sim gRPC push config dropped `authentication` | `authentication` absent from the created config | `{"scheme": ...}` echoed, credentials write-only | `AshA2A.Sim.GrpcHandler` |
| Sim card declared protocol 1.0 | `protocolVersion: "1.0"` on every interface | `"1.1"` | `AshA2A.Sim.Server` |
| F-01: gRPC status of `UnsupportedOperationError`, `VersionNotSupportedError`, `PushNotificationNotSupportedError` | `UNIMPLEMENTED` | `FAILED_PRECONDITION` (5.4) | `AshA2A.Transport.Grpc.Dispatch`, `AshA2A.Transport.GRPC.Server` |
| F-02: gRPC streaming RPCs lost the A2A error | `SendStreamingMessage` / `SendLiveMessage`: `NOT_FOUND` with no details; stale `ifGenerationMatch` answered `FAILED_PRECONDITION` `Task is not streamable` | `NOT_FOUND` + `ErrorInfo{TASK_NOT_FOUND}`, `ABORTED` + `ErrorInfo{TASK_GENERATION_MISMATCH}` (10.6) | `AshA2A.Transport.GRPC.Server` |
| F-03: gRPC `SubscribeToTask` events carried generation 0 | `status_update` with no `generation` | every event carries the generation the task store gave that mutation; a mutation that landed before the subscription is replayed, not lost | `AshA2A.Transport.GRPC.Server` (`follow/5` reads the stored task's timeline) |
| F-07 (gRPC): `SendStreamingMessage` refused non-streaming and interrupting skills | `FAILED_PRECONDITION` `Task is not streamable` | every skill streams: `Task` first (sent before the handler runs, so its id is usable at once), one event per stored mutation, ending on a terminal or interrupted status (3.1.2) | `AshA2A.Transport.GRPC.Server`, `AshA2A.Transport.Runtime` (detached streams are drained) |
| F-08 (gRPC half): inline push config and unary publication | `configuration.taskPushNotificationConfig` dropped over gRPC; a task answered by `SendMessage` / `CancelTask` fired no webhook unless the host handler published it | stored as `CreateTaskPushNotificationConfig` would; the server publishes the answered task | `AshA2A.Transport.GRPC.Server` (the `AshA2A.Sim.GrpcHandler` workaround is removed) |

## Version gating: closed (VG-01..VG-03)

Decision (2026-11-16): **no gate.** Section 5.4 "Error Code Mappings" of `docs/specification.md`
is the same table at tags `v1.0.1` and `v1.1.0-rc` for the nine error types both versions have
(`git -C a2a show v1.0.1:docs/specification.md`, `git -C a2a show v1.1.0-rc:docs/specification.md`);
v1.1 only adds `TaskGenerationMismatchError` (`-32010`, `ABORTED`, `409`). The two versions do not
differ, so nothing depends on the negotiated version, and the values recorded earlier from a TCK
pin (409 / 415 / 502) appear in neither text.

| Case | Error | Section 5.4, v1.0.1 and v1.1.0-rc | Served and returned by the helpers |
|---|---|---|---|
| VG-01 | `TaskNotCancelableError` (`-32002`) | `FAILED_PRECONDITION`, `400 Bad Request` | `400` |
| VG-02 | `ContentTypeNotSupportedError` (`-32005`) | `INVALID_ARGUMENT`, `400 Bad Request` | `400` |
| VG-03 | `InvalidAgentResponseError` (`-32006`) | `INTERNAL`, `500 Internal Server Error` | `500` |

One table now holds every binding's representation of every error code:
`AshA2A.Protocol.JSONRPC.Error.bindings/1`. `AshA2A.Transport.HTTPJSON.status_for/1` and the gRPC
dispatch table are generated from it at compile time, and `Error.http_status/1`,
`Error.spec_http_status/1`, `Error.grpc_code/1`, `Error.grpc_status/1` and
`Error.status_name_for_code/1` read it, so the helper and the served status cannot disagree.

Evidence: `test/http_json_error_status_table_test.exs` drives every error type through the real
HTTP+JSON plug at `A2A-Version` 1.0 and 1.1 and compares the served status, the body's `status`
name and `ErrorInfo` reason with the table and with the gRPC dispatch. The parity check asserts
VG-01 (`CancelTask | completed task is not cancelable`) and VG-02
(`SendMessage | a part in a media type the agent does not accept`) on every binding at v1.1 and
on the v1.0 pass. VG-03 has no parity vector: nothing in the library produces
`InvalidAgentResponseError` on the wire (only a host's own agent can return it), so the table
test is its evidence.

Also closed:

- `message/stream` court (h) of `test/ash_a2a_v1_owner_scope_test.exs`: the redacted
  `{:error, reason}` answer of `lib/ash_a2a/a2a_transport/sse.ex` is still reachable and has a
  real trigger again, court (h2): a stream to an agent that is down, whose exit reason carries
  the whole call (message and the caller's verified credential). The answer is `-32000` with an
  opaque ref.

Still open:

- `-32603` passes free-form `data` through (`Error.internal_error("boom")` serializes
  `"data": "boom"`), while section 9.5 describes `error.data` as an array of `@type` objects.

## Advisory

- HTTP+JSON responses carry `content-type: application/json`. Spec 11.1 says
  `application/a2a+json` SHOULD be used. The script does not fail on it.
- The HTTP statuses 400/400/500 above follow the spec table (5.4). The
  upstream TCK pinned 409/415/502 for the same three errors; a TCK run against
  this library will disagree until the TCK follows the specification.
