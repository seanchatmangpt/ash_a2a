# A2A Spec-Version Mapping

Maps A2A JSON-RPC methods to the vendored `:a2a` 0.2.0 Plug behavior as
observed by `test/ash_a2a_a2a_methods_test.exs`, and to the SA2A profile
id in force for release v26.9.20.

Version: v26.9.20

## Profile identifiers

| Constant | Value |
|----------|-------|
| `AshA2A.Semantic.Extension.profile_id/0` | `SA2A-PROFILE-v26.9.20` |
| `AshA2A.Semantic.Extension.profile_uri/0` | `urn:sa2a:profile:v26.9.20` |
| `AshA2A.Semantic.Extension.profile_version/0` | `v26.9.20` |
| `AshA2A.SA2A.Conformance` receipt profile | `SA2A-STRICT-v26.9.20` |

## Method mapping

| A2A (v1 name) | Wire method | Observed status | Test |
|---------------|-------------|-----------------|------|
| SendMessage | `message/send` | implemented | `message/send returns a task result` |
| SendStreamingMessage | `message/stream` | implemented (SSE) | `message/stream answers with an SSE event stream` |
| GetTask | `tasks/get` | implemented | `tasks/get ...` (found and -32001) |
| CancelTask | `tasks/cancel` | implemented (-32002 on completed) | `tasks/cancel ...` |
| SubscribeToTask | `tasks/resubscribe` | UNSUPPORTED: typed -32004 | `tasks/resubscribe ...` |
| GetExtendedAgentCard | `agent/getAuthenticatedExtendedCard` | UNSUPPORTED: typed -32004 | `agent/getAuthenticatedExtendedCard ...` |
| Push notification config | `tasks/pushNotificationConfig/*` | UNSUPPORTED in vendored plug | see `test/ash_a2a_push_notification_config_test.exs` |

## External TCK

No external A2A TCK is vendored in this repository; TCK conformance is
UNSUPPORTED (not run).

## See Also

- `docs/reference/a2a-endpoint-contract.md`
- `docs/rfc/RFC-SA2A-001-v26.9.16.md`
