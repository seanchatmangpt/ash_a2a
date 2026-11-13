# A2A Spec-Version Mapping

Maps every A2A JSON-RPC method (v1 PascalCase canonical name and the
slash-style wire name it dispatches to, `@method_aliases` in
`lib/ash_a2a/protocol/jsonrpc.ex`) to the wire behavior observed through two transports:
the in-repo `AshA2A.Protocol.Plug` (a2a-elixir 0.3.0 lineage, now
speaking A2A protocol v1.0 wire shapes, `lib/ash_a2a/protocol/`), and
the ash_a2a-owned `AshA2A.A2ATransport.Plug`.

Version: v26.11.13

The method table is not hand-maintained prose:
`test/ash_a2a/a2a_transport/spec_mapping_doc_test.exs` drives every row
through both real plugs, and fails when an observed outcome differs from the
table, when a method or alias exists in `AshA2A.Protocol.JSONRPC`'s dispatch
surface but not here, or when the `Version:` line differs from `mix.exs`.

## Protocol and profile identifiers

| Constant | Value |
|----------|-------|
| Agent card interface `protocolVersion` (`supportedInterfaces[]`; not a top-level card field in v1.0) | `1.1` (`AshA2A.Protocol.Version.protocol_version/0`, `lib/ash_a2a/protocol/version.ex`) |
| `AshA2A.Semantic.Extension.profile_id/0` | `SA2A-PROFILE-v26.9.20` |
| `AshA2A.Semantic.Extension.profile_uri/0` | `urn:sa2a:profile:v26.9.20` |
| `AshA2A.Semantic.Extension.profile_version/0` | `v26.9.20` |
| `AshA2A.SA2A.Conformance.profile/0` | `SA2A-STRICT-v26.9.20` |

The SA2A profile constants are bumped only by the release process; they
name the profile revision, not the package version. The `protocolVersion`
above is `AshA2A.Protocol.Version.protocol_version/0` — the single source
of truth stamped on every emitted agent-card interface.

## Method mapping

Outcome vocabulary: `result` (JSON-RPC success), `sse` (a
`text/event-stream` response), `error <code>` (JSON-RPC error code). Rows are
observed on an existing task; the `AshA2A.A2ATransport.Plug` column is
observed with `push_notifications: true` and an `:extended_card` provider
configured on an authenticated conn.

| A2A v1 method (PascalCase, canonical) | Slash-style wire name | `AshA2A.Protocol.Plug` | `AshA2A.A2ATransport.Plug` |
|---------------|-------------|------------|----------------------------|
| SendMessage | `message/send` | result | result |
| SendStreamingMessage | `message/stream` | error -32004 | sse |
| GetTask | `tasks/get` | result | result |
| CancelTask | `tasks/cancel` | error -32002 | error -32002 |
| ListTasks | `tasks/list` | result | result |
| SubscribeToTask | `tasks/resubscribe` | error -32004 | error -32004 |
| GetExtendedAgentCard | `agent/getAuthenticatedExtendedCard` | error -32007 | result |
| CreateTaskPushNotificationConfig | `tasks/pushNotificationConfig/set` | error -32003 | result |
| GetTaskPushNotificationConfig | `tasks/pushNotificationConfig/get` | error -32003 | result |
| ListTaskPushNotificationConfigs | `tasks/pushNotificationConfig/list` | error -32003 | result |
| DeleteTaskPushNotificationConfig | `tasks/pushNotificationConfig/delete` | error -32003 | result |

`tasks/cancel` is observed on a completed task, so `-32002`
(TASK_NOT_CANCELABLE) is the correct outcome on both transports.

† `tasks/resubscribe` under `AshA2A.A2ATransport.Plug`: the probe task is
terminal with no retained event log, so spec §3.1.6 (STREAM-SUB-003 MUST)
refuses it with `-32004` UnsupportedOperationError. A task with retained
log history is served as SSE (snapshot, `Last-Event-ID` replay, live
events to terminal) — the vocabulary cell records the probe outcome only.

v1.0 notes on what the outcome vocabulary hides:

- `message/stream` and `tasks/resubscribe` SSE frames are wrapped
  `StreamResponse` frames (`{"task": ...}`, `{"statusUpdate": ...}`,
  `{"artifactUpdate": ...}`); v1.0 dropped the `final` boolean — the
  stream simply ends at a terminal state.
- Every A2A-specific error in the table (`-32001`..`-32009`) plus
  `-32602` serializes its `data` as a `google.rpc.ErrorInfo` object
  (domain `a2a-protocol.org`) — `-32001` TASK_NOT_FOUND, `-32002`
  TASK_NOT_CANCELABLE, `-32003` PUSH_NOTIFICATION_NOT_SUPPORTED,
  `-32004` UNSUPPORTED_OPERATION, `-32602` INVALID_PARAMS, and the rest
  of the registry in
  `lib/ash_a2a/protocol/jsonrpc/error.ex`.

## A2A v1.1 additions (target v1.1.0, upstream tag `v1.1.0-rc`)

Not part of the drift-court table above (the court binds only the 4-column
rows driven through both plugs). These rows are the v1.1 delta. Overall v1.1
Standing is PARTIAL; per-row courts and standings are in the
[A2A v1.1 conformance statement](a2a-v1-1-conformance.md), which is the
authority for this table. No v1.1 TCK verdict exists.

| v1.1 surface | Wire name / field | Binding |
|--------------|-------------------|---------|
| SendLiveMessage (stream of `StreamRequest`) | gRPC `SendLiveMessage`; HTTP `POST /message:live`; no JSON-RPC method | gRPC, HTTP+JSON |
| `StreamError` frame | `StreamResponse.error` | live bindings |
| `TaskMessageUpdateEvent` | `StreamResponse.messageUpdate` | all streams, `A2A-Version` >= 1.1 |
| Task timeline | `Task.timeline[]` (`TimelineEntry`), `timelineLength` on GetTask / ListTasks / SendMessageConfiguration | all |
| Task generation | `Task.generation`, `generation` on status/artifact/message update events | all |
| Artifact generation and role | `startGeneration`, `endGeneration`, `role` | all |
| Optimistic concurrency | `SendMessageConfiguration.ifGenerationMatch`; mismatch JSON-RPC `-32010`, HTTP 409 `ABORTED` | all |
| Long poll | `GetTaskRequest.currentGeneration` (bounded by `config :ash_a2a, :long_poll_timeout_ms`) | all |
| Resume | `SubscribeToTaskRequest.lastSeenGeneration` | all |
| User artifacts | `AgentCapabilities.userArtifacts`, `SendMessageRequest.artifactUpdates` | all |
| Push config version | `TaskPushNotificationConfig.protocolVersion` | all |

Version negotiation: `A2A-Version: 1.1` selects v1.1 behavior; `1.0`/`1.0.1`
remain served; 0.3 is decode-only legacy.

## Defaults and fail-closed behavior of `AshA2A.A2ATransport.Plug`

| Condition | Outcome |
|-----------|---------|
| `push_notifications` not set (default `false`) | push methods `error -32003`; inline `configuration.pushNotificationConfig` on `message/*` refused with `-32003` |
| webhook URL not https, private/loopback/link-local/metadata, unresolvable, or with userinfo | `error -32602`, `data.code` = `refused_webhook_*` |
| no `:extended_card` provider | `agent/getAuthenticatedExtendedCard` `error -32007` |
| provider configured, no verified identity on the conn | HTTP 401, `error -32600` |
| `AshA2A.A2ATransport` instance not running | `message/stream`, `tasks/resubscribe` and push fall back to the `AshA2A.Protocol.Plug` column |
| task owned by a different verified principal (`tasks/get`, `tasks/cancel`, `tasks/resubscribe`, push config, continuation) | `error -32001`, same as a missing task |
| `params.metadata` carries `a2a.auth` or `ash_a2a.owner` | keys dropped before dispatch; the verified identity cannot be overwritten |
| any task returned or published (response, SSE frame, webhook body) | `a2a.auth`, owner key and stream ref stripped from `metadata` |

`tasks/list` on `AshA2A.A2ATransport.Plug` is now owner-scoped (verified principal,
`-32001`-indistinguishable) for full `AshA2A.Agent` agents and for a bare
`AshA2A.Protocol.Agent`, which answers the same owner-scoped message through
`AshA2A.Transport.Runtime.list_tasks_for/3` (store read-through; anonymous callers
never list).

## Durability

Task state lives in each agent GenServer; the transport's event log and push
config store are node-local ETS. Durable tasks are implemented through the
pluggable `AshA2A.Protocol.TaskStore` seam: `AshA2A.TaskStore.Ekv` survives an
agent restart, and plug-created tasks are readable from a second node over a
real 2-node EKV cluster (courts `test/ash_a2a_v1_taskstore_durability_test.exs`
and `test/ash_a2a_v1_multinode_continuity_test.exs`). Pinned gaps:
`tasks/list` pages the in-memory map only, and a mid-flight stream stays
node-local (a resubscribed stream on a fresh agent never progresses by
itself). Durable cross-node task continuity: PARTIAL.

## External TCK

The upstream A2A TCK (`a2aproject/a2a-tck`) compatibility suite ran once
against all three bindings; latest recorded verdict 2026-10-13 at
`13622178`: 79.0% overall, 234 passed / 31 skipped / 0 failed — see
[A2A v1.0 conformance statement](a2a-v1-conformance.md). TCK certification
remains UNSUPPORTED (not claimed). The mapping table above is local,
two-transport differential evidence only.

## See Also

- `docs/reference/a2a-endpoint-contract.md`
- [A2A v1.1 conformance statement](a2a-v1-1-conformance.md)
- [v1.1 live and generations how-to](../how-to/v1-1-live-and-generations.md)
- `docs/archive/rfc/RFC-SA2A-001-v26.9.16.md`
- `lib/ash_a2a/a2a_transport/plug.ex`
