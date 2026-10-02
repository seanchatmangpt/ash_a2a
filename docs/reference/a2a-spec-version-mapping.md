# A2A Spec-Version Mapping

Maps every A2A JSON-RPC method (canonical slash name and v0.3 PascalCase
alias) to the wire behavior observed through two transports: the vendored
`:a2a` 0.2 `A2A.Plug`, and the ash_a2a-owned `AshA2A.A2ATransport.Plug`.

Version: v26.9.31

The method table is not hand-maintained prose:
`test/ash_a2a/a2a_transport/spec_mapping_doc_test.exs` drives every row
through both real plugs, and fails when an observed outcome differs from the
table, when a method or alias exists in `A2A.JSONRPC`'s dispatch surface but
not here, or when the `Version:` line differs from `mix.exs`.

## Protocol and profile identifiers

| Constant | Value |
|----------|-------|
| Agent card `protocolVersion` / interface `protocolVersion` | `0.3.0` |
| `AshA2A.Semantic.Extension.profile_id/0` | `SA2A-PROFILE-v26.9.20` |
| `AshA2A.Semantic.Extension.profile_uri/0` | `urn:sa2a:profile:v26.9.20` |
| `AshA2A.Semantic.Extension.profile_version/0` | `v26.9.20` |
| `AshA2A.SA2A.Conformance.profile/0` | `SA2A-STRICT-v26.9.20` |

The SA2A profile constants are bumped only by the release process; they
name the profile revision, not the package version.

## Method mapping

Outcome vocabulary: `result` (JSON-RPC success), `sse` (a
`text/event-stream` response), `error <code>` (JSON-RPC error code). Rows are
observed on an existing task; the `AshA2A.A2ATransport.Plug` column is
observed with `push_notifications: true` and an `:extended_card` provider
configured on an authenticated conn.

| A2A v0.3 name | Wire method | `A2A.Plug` | `AshA2A.A2ATransport.Plug` |
|---------------|-------------|------------|----------------------------|
| SendMessage | `message/send` | result | result |
| SendStreamingMessage | `message/stream` | sse | sse |
| GetTask | `tasks/get` | result | result |
| CancelTask | `tasks/cancel` | error -32002 | error -32002 |
| ListTasks | `tasks/list` | result | result |
| SubscribeToTask | `tasks/resubscribe` | error -32004 | sse |
| GetExtendedAgentCard | `agent/getAuthenticatedExtendedCard` | error -32004 | result |
| CreateTaskPushNotificationConfig | `tasks/pushNotificationConfig/set` | error -32003 | result |
| GetTaskPushNotificationConfig | `tasks/pushNotificationConfig/get` | error -32003 | result |
| ListTaskPushNotificationConfigs | `tasks/pushNotificationConfig/list` | error -32003 | result |
| DeleteTaskPushNotificationConfig | `tasks/pushNotificationConfig/delete` | error -32003 | result |

`tasks/cancel` is observed on a completed task, so `-32002`
(TaskNotCancelable) is the correct outcome on both transports.

## Defaults and fail-closed behavior of `AshA2A.A2ATransport.Plug`

| Condition | Outcome |
|-----------|---------|
| `push_notifications` not set (default `false`) | push methods `error -32003`; inline `configuration.pushNotificationConfig` on `message/*` refused with `-32003` |
| webhook URL not https, private/loopback/link-local/metadata, unresolvable, or with userinfo | `error -32602`, `data.code` = `refused_webhook_*` |
| no `:extended_card` provider | `agent/getAuthenticatedExtendedCard` `error -32007` |
| provider configured, no verified identity on the conn | HTTP 401, `error -32600` |
| `AshA2A.A2ATransport` instance not running | `message/stream`, `tasks/resubscribe` and push fall back to the `A2A.Plug` column |
| task owned by a different verified principal (`tasks/get`, `tasks/cancel`, `tasks/resubscribe`, push config, continuation) | `error -32001`, same as a missing task |
| `params.metadata` carries `a2a.auth` or `ash_a2a.owner` | keys dropped before dispatch; the verified identity cannot be overwritten |
| any task returned or published (response, SSE frame, webhook body) | `a2a.auth`, owner key and stream ref stripped from `metadata` |

`tasks/list` is still delegated to `A2A.Plug` and is **not** owner-filtered on this plug;
use `AshA2A.Transport.Plug` where owner-scoped listing is required.

## Durability

Task state lives in each agent GenServer; the transport's event log and push
config store are node-local ETS. A task created on one node cannot be
resubscribed or configured through another node, and nothing survives a
restart. Durable, multi-node tasks need an `A2A.TaskStore` wired through
`AshA2A.Agent` plus a persisted event log: BLOCKED (not implemented).

## External TCK

No run of the upstream A2A TCK (`a2aproject/a2a-tck`) against this server
has been recorded; TCK conformance is UNSUPPORTED (not run). The table above
is local, two-transport differential evidence only.

## See Also

- `docs/reference/a2a-endpoint-contract.md`
- `docs/rfc/RFC-SA2A-001-v26.9.16.md`
- `lib/ash_a2a/a2a_transport/plug.ex`
