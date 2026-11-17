# A2A error coverage

Standing: VERIFIED for -32006 (new in this revision) and the parity vectors listed below; the
other rows cite tests that already existed and were not re-run end to end here. The reference is
specification section 5.4 at tags `v1.0.1` and `v1.1.0-rc` (the table is the same text; v1.1 only
adds `TaskGenerationMismatchError`). The one status table is
`AshA2A.Protocol.JSONRPC.Error.bindings/1`; every row below has its three mappings and its
`google.rpc.ErrorInfo` reason (domain `a2a-protocol.org`) there.

Every A2A error type is emitted by this server. None is "not applicable by design"; the three
rows where the simulation server cannot reach the situation on every binding say why in the notes
and name the library tests that drive it on the real transports.

| Error | Trigger | Emitted by | JSON-RPC / HTTP / gRPC | ErrorInfo reason | Test | Parity vector |
|---|---|---|---|---|---|---|
| TaskNotFoundError | unknown task id, or a task owned by another caller (no existence leak) | `Protocol.Plug`, `Transport.Plug`, `Transport.HTTPJSON`, `Grpc.Server` | -32001 / 404 / NOT_FOUND (5) | `TASK_NOT_FOUND` | `test/http_json_error_status_table_test.exs`, `test/ash_a2a_v1_error_registry_test.exs`, sim prover probes on all bindings | `run_errors`: unknown task (GetTask, CancelTask, SubscribeToTask, SendMessage, SendStreamingMessage), another caller's task |
| TaskNotCancelableError | cancel of a task in a terminal state | `handle_cancel`, `Transport.Runtime` | -32002 / 400 / FAILED_PRECONDITION (9) | `TASK_NOT_CANCELABLE` | `test/ash_a2a/transport/transport_court_test.exs`, `test/ash_a2a_v1_grpc_must_test.exs` | `run_errors`, `run_errors_core`: completed task is not cancelable |
| PushNotificationNotSupportedError | a push-config method on a mount whose card does not declare `pushNotifications` | `A2ATransport.PushConfigRPC`, `Transport.Plug`, `Transport.HTTPJSON`, `Grpc.Server` | -32003 / 400 / FAILED_PRECONDITION (9) | `PUSH_NOTIFICATION_NOT_SUPPORTED` | `test/ash_a2a_v1_push_httpjson_test.exs`, `test/ash_a2a/a2a_transport/push_notification_test.exs`, sim prover on `/jsonrpc` | `run_unconfigured_card_and_push` on the `/jsonrpc` mount (JSON-RPC only; the sim's `/rest` and gRPC listeners declare push, so HTTP+JSON and gRPC are driven by the library tests) |
| UnsupportedOperationError | subscribe to, or send to, a terminal task; `artifactUpdates` without `userArtifacts` | `Transport.Runtime`, `ClientArtifacts` | -32004 / 400 / FAILED_PRECONDITION (9) | `UNSUPPORTED_OPERATION` | `test/ash_a2a_v1_httpjson_tck_closures_test.exs`, `test/ash_a2a_transport_grpc_server_test.exs` | `run_errors`: terminal task (SubscribeToTask, SendMessage); `run_user_artifacts` |
| ContentTypeNotSupportedError | a part whose media type the card's `defaultInputModes` does not list | `InputModeValidator` | -32005 / 400 / INVALID_ARGUMENT (3) | `CONTENT_TYPE_NOT_SUPPORTED` | `test/http_json_plug_wiring_test.exs`, `test/grpc_server_wiring_test.exs` | `run_content_type_error` on all four bindings |
| InvalidAgentResponseError | the agent's reply is not a valid A2A response: reply parts that are not a list of text, file or JSON-valued data parts (`AgentReply.validate_parts/1`), or a bare Message answering a task-scoped request (legacy `Protocol.Agent`, `:message_on_task`) | `Transport.Runtime.safe_handle/3` (stores the task `FAILED` and answers the error), `Protocol.Plug`, `Protocol.Plug.SSE`; mapped by `Transport.Plug.reason_error/1` for HTTP+JSON and gRPC | -32006 / 500 / INTERNAL (13) | `INVALID_AGENT_RESPONSE` | `test/ash_a2a/sim/invalid_agent_response_test.exs` (both JSON-RPC mounts, HTTP+JSON, gRPC), sim prover probe `bad_reply`, MCP coverage entry | `run_invalid_agent_response` on all four bindings (sim skill `bad_reply`) |
| ExtendedAgentCardNotConfiguredError | `GetExtendedAgentCard` on a mount with no extended-card provider | `A2ATransport.ExtendedCard`, `Transport.Plug`, `Transport.HTTPJSON`, `Grpc.Dispatch` | -32007 / 400 / FAILED_PRECONDITION (9) | `EXTENDED_AGENT_CARD_NOT_CONFIGURED` | `test/ash_a2a/a2a_transport/extended_card_test.exs`, `test/ash_a2a_v1_extended_httpjson_test.exs`, `test/ash_a2a_v1_grpc_must_test.exs` | `run_unconfigured_card_and_push` on the `/jsonrpc` mount (JSON-RPC only; the sim's other mounts serve an extended card) |
| ExtensionSupportRequiredError | the agent card lists an extension as `required` and the request does not activate it | `Protocol.Extension`, `A2ATransport.Plug`, `Grpc.Server` | -32008 / 400 / FAILED_PRECONDITION (9) | `EXTENSION_SUPPORT_REQUIRED` | `test/ash_a2a_protocol_extension_e2e_test.exs`, `test/grpc_extension_gate_test.exs`, `test/grpc_wave2_errorinfo_test.exs` | none: the sim declares no required extension, and declaring one would make every sim client (prover, parity, MCP) fail until it activates it |
| VersionNotSupportedError | an `A2A-Version` the server does not serve | `Protocol.Version`, every transport | -32009 / 400 / FAILED_PRECONDITION (9) | `VERSION_NOT_SUPPORTED` (metadata `supportedVersions`) | `test/error_version_table_test.exs`, `test/ash_a2a/transport/transport_court_test.exs` | `run_errors`, `run_errors_core`: A2A-Version 9.9 |
| TaskGenerationMismatchError (v1.1 only) | `ifGenerationMatch` names a generation the task no longer has | `Transport.Runtime`, `Task.Generation` | -32010 / 409 / ABORTED (10) | `TASK_GENERATION_MISMATCH` (metadata `expectedGeneration`, `actualGeneration`) | `test/http_json_generation_stream_test.exs`, `test/grpc_generation_gaps_test.exs`, `test/task_generation_guards_test.exs` | `run_errors`: ifGenerationMatch mismatch (SendMessage, SendStreamingMessage; live stream `StreamError` ABORTED) |

## Notes

- -32006 used to have a constructor and a table row but no code path that emitted it on the HTTP+JSON,
  gRPC or `/jsonrpc` bindings: a reply that was not a list of parts became -32603 or crashed the
  encoder. `Transport.Runtime.safe_handle/3` now validates it. The stored task ends `FAILED` with the
  fixed text `Error: invalid agent response`; the offending value never reaches the caller (the
  detail is logged under no ref and kept off the wire).
- -32001 is deliberately shared with policy denial so a denied caller cannot tell "forbidden" from
  "absent" (see `Error.task_not_found/2`).
- Standard JSON-RPC codes (-32700, -32600, -32601, -32602, -32603) and the library's -32000 (server
  busy, HTTP 503 / UNAVAILABLE) are not A2A error types; they are covered by `run_jsonrpc_protocol_errors`,
  `run_grpc_protocol_errors` and `expect_generic_error` in `scripts/a2a_v1_1_parity/parity.py`.
