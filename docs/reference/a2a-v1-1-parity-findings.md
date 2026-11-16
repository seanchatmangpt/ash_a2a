# A2A v1.1 parity findings

Findings of the parity check (`mix ash_a2a.sim --parity`,
[how to run it](../how-to/check-a2a-v1-1-parity.md)) against the upstream
specification at tag `v1.1.0-rc`. Section numbers refer to
`docs/specification.md` at that tag.

Every response the simulation server sends is byte-identical to the reference
encoder on all three bindings: the `strict`, `wire` and `required` rows all
pass. The open findings below are wrong statuses, missing events and one
missing method.

Each open finding has rows in `scripts/a2a_v1_1_parity/known_defects.json`.
To reproduce one, start the server and run the script without `--known`:

```console
mix ash_a2a.sim --http-port 47101 --grpc-port 47102
/tmp/a2a_v1_1_parity/venv/bin/python scripts/a2a_v1_1_parity/parity.py \
  --http http://127.0.0.1:47101 --grpc 127.0.0.1:47102 --trace --only grpc --groups errors
```

`--only` takes `grpc`, `http+json`, `jsonrpc` or `jsonrpc:/jsonrpc`;
`--groups` takes `card`, `send`, `get`, `streams`, `push`, `live`,
`artifacts`, `errors`, `cross`.

## Needs owner

These live in files another change owns.

### F-01: gRPC answers UNIMPLEMENTED for UnsupportedOperationError and VersionNotSupportedError

- **Where:** `lib/ash_a2a/transport/grpc/dispatch.ex` (status mapping).
- **Repro:** `--only grpc --groups errors,artifacts`. Rows `SubscribeToTask | terminal task`, `SendMessage | message to a terminal task`, `GetTask | A2A-Version 9.9`, `SendMessage | userArtifacts: client artifact_updates`.
- **Sent:** status `UNIMPLEMENTED` (12) with `ErrorInfo` reason `UNSUPPORTED_OPERATION` or `VERSION_NOT_SUPPORTED`.
- **Expected (5.4):** status `FAILED_PRECONDITION` (9) for both error types. The `ErrorInfo` is already right.

### F-02: gRPC streaming RPCs lose the A2A error

- **Where:** `lib/ash_a2a/transport/grpc/server.ex` (`SendStreamingMessage`, `SendLiveMessage`).
- **Repro:** `--only grpc --groups errors,live`.
- **Sent:** `SendStreamingMessage` to an unknown task: `NOT_FOUND` with no `grpc-status-details-bin`. `SendStreamingMessage` with a stale `ifGenerationMatch`: `FAILED_PRECONDITION`, message `Task is not streamable: {:error, :redacted}`. `SendLiveMessage` opening with `subscribe` to an unknown task: `NOT_FOUND` with no details.
- **Expected (5.4, 10.6):** `NOT_FOUND` with `ErrorInfo{reason: "TASK_NOT_FOUND", domain: "a2a-protocol.org"}`; `ABORTED` with `ErrorInfo{reason: "TASK_GENERATION_MISMATCH"}` (3.2.2). 10.6 says the `ErrorInfo` MUST be present for A2A errors.

### F-03: gRPC SubscribeToTask status events carry generation 0

- **Where:** `lib/ash_a2a/transport/grpc/server.ex` (subscribe stream), fed by `lib/ash_a2a/a2a_transport/task_events.ex`.
- **Repro:** `--only grpc --groups streams`. Rows `SubscribeToTask | Task first, then updates to terminal` and `SubscribeToTask | lastSeenGeneration resumes without a snapshot`.
- **Sent:** `StreamResponse{status_update{... status{state: TASK_STATE_COMPLETED}}}` with field 5 (`generation`) absent, after a `Task` snapshot at generation 2.
- **Expected (3.2.7):** each event carries the task's generation after the mutation; `0` tells a client the server has no generation support. Here: `artifact_update` at 3, `status_update` at 4.

### F-04: stream generations do not agree with the stored task

- **Where:** the generation of streamed chunks is assigned outside the task store: `lib/ash_a2a/a2a_transport/task_events.ex` (`assign_generation/5` counts per logged event) and the stream wrapper in `lib/ash_a2a/protocol/agent/runtime.ex` (folds all chunks into one stored mutation). `lib/ash_a2a/transport/http_json.ex` (`send_chunk_frame/5`) stamps every chunk with the snapshot's generation.
- **Repro:** `--groups streams`, `SendStreamingMessage` with skill `list_notes` and data `{"stream": true}`, then `GetTask`.
- **Sent:** gRPC and JSON-RPC: one `artifactUpdate` per chunk with generations 4, 5, 6, ... up to N, then `GetTask` answers `generation: "5"`. HTTP+JSON: `task` at 3, every `artifactUpdate` at 3, `statusUpdate` at 5.
- **Expected (3.2.7):** one emitted event per mutation, its generation the task's generation after it, increasing by exactly 1, and equal to what `GetTask` then reports. Either each chunk is a stored mutation, or the chunks of one mutation are one event.

### F-05: SubscribeToTask does not deliver the artifact mutation

- **Where:** `lib/ash_a2a/a2a_transport/task_events.ex` and the subscribe paths that read it (`lib/ash_a2a/transport/http_json.ex` `handle_subscribe/3`, `lib/ash_a2a/a2a_transport/plug.ex`, `lib/ash_a2a/transport/plug.ex`).
- **Repro:** `--only http+json --groups streams`: send `slow_count` with `returnImmediately`, then `GET /tasks/{id}:subscribe`.
- **Sent:** `{"task": {... "generation": "2"}}`, then `{"statusUpdate": {... "generation": "4"}}`.
- **Expected (3.1.6, 3.2.7):** the artifact written at generation 3 arrives as `{"artifactUpdate": {..., "generation": "3"}}` between the two. A gap tells the client it missed an event. On the `/jsonrpc` mount a subscribe with `lastSeenGeneration` also never reaches the terminal status.

### F-07: streaming a message whose task interrupts is refused

- **Where:** the stream path of `lib/ash_a2a/transport/grpc/server.ex` and `lib/ash_a2a/a2a_transport/plug.ex` / `lib/ash_a2a/transport/runtime.ex`.
- **Repro:** `--groups streams,errors`: `SendStreamingMessage` with skill `create_note` and data `{"body": "no title"}` (the task parks at input-required).
- **Sent:** gRPC `FAILED_PRECONDITION` `Task is not streamable: {:error, :redacted}`; JSON-RPC `-32004` `UNSUPPORTED_OPERATION`. With a stale `ifGenerationMatch`, JSON-RPC also answers `-32004`.
- **Expected (3.1.2):** a stream that opens with the `Task` and carries the `TASK_STATE_INPUT_REQUIRED` status; an interrupted state does not close or refuse the stream. HTTP+JSON does this. A stale `ifGenerationMatch` is `-32010` (3.2.2).

## Open

Not owned by another change; not fixed yet.

### F-06: SendLiveMessage skips the working status on the downlink

- **Where:** `lib/ash_a2a/transport/live/session.ex` (`observe/2`).
- **Repro:** `--groups live`, row `client message arrives as TaskMessageUpdateEvent`.
- **Sent:** after the follow-up message: `messageUpdate` at generation 5, `artifactUpdate` at 7, `statusUpdate` at 8.
- **Expected (3.2.7):** the `TASK_STATE_WORKING` status written at generation 6 as its own `statusUpdate`.

### F-08: a task that finishes after the call returned sends no push notification

- **Where:** completion of a detached (`returnImmediately`) task is not published to `AshA2A.A2ATransport.TaskEvents`; `lib/ash_a2a/transport/http_json.ex` `publish_task/2` runs only on the request path. Over gRPC, `configuration.taskPushNotificationConfig` is also not stored (`lib/ash_a2a/sim/grpc_handler.ex` `handle_send/3`, `lib/ash_a2a/transport/grpc/server.ex`).
- **Repro:** `--groups push`: `SendMessage` with skill `slow_count`, `configuration.returnImmediately: true` and `configuration.taskPushNotificationConfig: {"id": ..., "url": ...}`.
- **Sent:** HTTP+JSON and JSON-RPC: one delivery with the submitted task, none when it completes. gRPC: no delivery, and `ListTaskPushNotificationConfigs` answers no config.
- **Expected (3.5.1, 4.3.3):** a delivery whose body is `{"statusUpdate": {... "state": "TASK_STATE_COMPLETED" ...}}`; an inline config is equivalent to `CreateTaskPushNotificationConfig` (3.2.2).

### F-09: 401 and 403 are not in the binding's error format

- **Where:** `lib/ash_a2a/protocol/plug/auth.ex`, which answers before the transport.
- **Repro:** `--groups errors`, rows `GetTask | no credentials` and `GetTask | token without the scope`.
- **Sent:** `401` with body `{"error":"Unauthorized"}`; `403` with `{"error":"insufficient_scope","scope":"a2a:invoke"}`, on every HTTP mount.
- **Expected (11.6):** over HTTP+JSON, `{"error":{"code":401,"status":"UNAUTHENTICATED","message":"..."}}` and `{"error":{"code":403,"status":"PERMISSION_DENIED","message":"..."}}`. Over JSON-RPC (9.5), a JSON-RPC error object. The gRPC statuses are right.

### F-10: the JSON-RPC binding has no SendLiveMessage

- **Where:** `lib/ash_a2a/a2a_transport/plug.ex` (`@method_aliases`).
- **Repro:** `--only jsonrpc --groups live`.
- **Sent:** `{"error":{"code":-32601,"message":"Method not found", ...}}`.
- **Expected (5.3):** the method `SendLiveMessage`, answering an SSE stream of JSON-RPC responses whose `result` is a `StreamResponse`, as `POST /message:live` does for HTTP+JSON.

### F-11: the owner-scoped /jsonrpc mount replays a message after the snapshot and drops the request id

- **Where:** `lib/ash_a2a/transport/plug.ex`.
- **Repro:** `--only jsonrpc:/jsonrpc --groups streams,errors`.
- **Sent:** `SendStreamingMessage`: `task` at generation 3, then `messageUpdate` at 2. `GetTask` with `A2A-Version: 9.9`: `{"error":{"code":-32009,...},"id":null}`.
- **Expected:** no event at a generation the snapshot has passed (3.2.7); `id` equal to the request's (JSON-RPC 2.0).

## Fixed

Found by the check and fixed in the library.

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

Three of these touch files another change owns, each a few lines:
`AshA2A.Protocol.JSON` data-part decode (`integral_numbers/1`),
`AshA2A.A2ATransport.TaskEvents.put_generation/2` (string generation), and
nothing under `lib/ash_a2a/transport/grpc`.

## Advisory

- HTTP+JSON responses carry `content-type: application/json`. Spec 11.1 says
  `application/a2a+json` SHOULD be used. The script does not fail on it.
- The HTTP statuses 400/400/500 above follow the spec table (5.4). The
  upstream TCK pinned 409/415/502 for the same three errors; a TCK run against
  this library will disagree until the TCK follows the specification.
