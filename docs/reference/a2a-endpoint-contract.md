# A2A Endpoint Reference

The exact HTTP surface an AshA2A-served agent exposes: the in-repo wire
codec `AshA2A.Protocol.*` (`lib/ash_a2a/protocol/` — `plug.ex`,
`jsonrpc.ex`, `jsonrpc/error.ex`; ported from a2a-elixir 0.3.0,
Apache-2.0, see `lib/ash_a2a/protocol/NOTICE`) plus the ash_a2a-owned
wrapper `AshA2A.A2ATransport.Plug`, which implements the methods the base
plug hard-codes to refusals.
Protocol level: **A2A protocol v1.0, JSON-RPC 2.0 over HTTP POST**, with
SSE streaming for `message/stream` (wrapped `StreamResponse` frames). The
gRPC binding is served by `AshA2A.Transport.GRPC.Server` — the canonical
`lf.a2a.v1.A2AService` (9 unary + 2 server-streaming RPCs,
`SendStreamingMessage`/`SubscribeToTask`) over HTTP/2 via `:grpc_server`,
with protobuf messages bridged to the codec's proto-JSON maps by
`Protobuf.JSON` (deps `:grpc_server`/`:grpc`/`:protobuf`). Push
notifications/webhooks are supported only through the owned transport with
`push_notifications: true` (see below); the bare `AshA2A.Protocol.Plug`
still refuses `tasks/resubscribe` (`-32004`) and
`tasks/pushNotificationConfig/*` (`-32003`).

## Endpoints

`AshA2A.Protocol.Plug` is mounted with `agent:` and `base_url:` options (see the
getting-started tutorial); all paths below are relative to the mount
point.

| Method + path | Purpose | Non-matching behavior |
| --- | --- | --- |
| `GET /.well-known/agent-card.json` | Agent card discovery (JSON, 200). Path configurable via `:agent_card_path`; disable built-in serving with `false`. | Wrong method → `405` with `Allow: GET`; any other path → `404`. |
| `POST /` (mount root) | JSON-RPC 2.0 dispatch. Path configurable via `:json_rpc_path`. | Body parse failure → JSON-RPC `-32700`. |

**HTTP status convention**: JSON-RPC calls always return HTTP **200**, for
successes and for JSON-RPC-level errors alike; transport-level problems
(401 from auth, 404/405 routing) are the exception.

A `nil` `base_url` at agent-card time raises `ArgumentError` — set it via
the `:base_url` option or `AshA2A.Protocol.Plug.put_base_url/2` in an upstream
plug/pipeline. Note the card builder's own URL default is
`http://localhost:4000` (`AshA2A.CapabilityIndex.AgentCardBuilder`), so a
production deployment must always set it.

## Agent card

`AshA2A.Info.agent_card/2` builds the card from the compiled capability
index (`AshA2A.CapabilityIndex.AgentCardBuilder.build_agent_card/2`)
filtered through the active release closure (6fcc5b7, PR #43). In legacy
mode (the `:capability_release_mode` default) the full index is
advertised and wire behavior is unchanged; in `:strict` mode only exact
skill ids present in the frozen released closure are advertised, and a
closure refusal raises `ArgumentError` at card-build time. The public
companions are `AshA2A.Info.released_capability_index/2` (returns `nil`
when the resource is not compiled; raises on a closure refusal) and the
non-raising `AshA2A.Info.released_capability_index_result/2`. The
projected card is an `AshA2A.Protocol.AgentCard`:

- `name` (default `"ash_a2a_agent"`), `description`, `version` (default
  `"0.1.0"`), `provider` — overridable via card opts.
- `skills`, sorted by id; per skill: `id` = `"<Resource>.<action>"`,
  `name` = override or the action name, `description` = override or derived
  from the real Ash action's description/type/arguments, `tags` = override
  or `[action.type | argument names]`.
- `default_input_modes`/`default_output_modes` default to
  `["text/plain"]` — note the dispatch contract below actually
  exchanges structured `Part.Data` (JSON) content.
- `supported_interfaces` defaults to
  `%{url: url, protocol_binding: "JSONRPC", protocol_version: "1.0"}`;
  the top-level `url` and `protocolVersion` fields are gone from the wire
  card — both live per-interface in `supportedInterfaces` only.
- `capabilities.extendedAgentCard` — set when the owned transport is
  mounted with an `:extended_card` provider; the card advertised at
  `/.well-known/agent-card.json` remains the public one, and the
  extended card is served only through the authenticated
  `agent/getAuthenticatedExtendedCard` RPC.

## JSON-RPC methods

| Method | Behavior |
| --- | --- |
| `message/send` | Synchronous dispatch; result is an A2A task object. |
| `message/stream` | SSE streaming response (`text/event-stream`): initial `{"task": ...}` snapshot frame, then wrapped `{"statusUpdate": ...}`/`{"artifactUpdate": ...}` frames. v1.0 has no `final` boolean — the stream simply ends when the task reaches a terminal state. |
| `tasks/get` / `tasks/cancel` / `tasks/list` | Task management within the agent process's lifetime (the task store is in-memory ETS, single node). |
| `tasks/resubscribe` | Supported via the owned transport (`AshA2A.A2ATransport.Plug` with a running `AshA2A.A2ATransport` instance): SSE response carrying the wrapped `{"task": ...}` snapshot, then the logged `{"statusUpdate": ...}`/`{"artifactUpdate": ...}` backlog after the SSE `Last-Event-ID` (if sent), then live events until the stream ends at a terminal state; every frame is `id: <task-local seq>`. Owner-scoped: a foreign or unknown task is `-32001`. Falls back to the base `AshA2A.Protocol.Plug`'s `-32004` when the transport instance is not running. |
| `tasks/pushNotificationConfig/*` | `set`/`get`/`list`/`delete` via the owned transport when `push_notifications: true` (A2A v1.0 wire shapes; the PascalCase aliases route identically). Configs are owner-scoped (unknown/foreign task → `-32001`), bounded to 16 per task (`:max_per_task`, beyond it the typed refusal `:refused_push_config_limit`); webhook URLs are admitted by `AshA2A.A2ATransport.WebhookPolicy` at `set` time (refused URL → `-32602` with `data.code: "refused_webhook_*"`); `authentication.credentials` is write-only (never echoed back). Without `push_notifications: true` (the default): `-32003`. |
| anything else | `-32601` method not found. |

## Error codes

`-32700` parse error · `-32600` invalid request · `-32601` method not
found · `-32602` invalid params · `-32603` internal error · `-32001` task
not found · `-32002` task not cancelable · `-32003` push notification not
supported · `-32004` unsupported operation (also
`agent/getAuthenticatedExtendedCard`).

Every A2A-specific error above (`-32001`..`-32009`) and `-32602`
serialize `data` as an array carrying one `google.rpc.ErrorInfo` object
(domain `a2a-protocol.org`):

| Code | `ErrorInfo.reason` |
| --- | --- |
| `-32001` | `TASK_NOT_FOUND` (also the policy-denial stamp for the same code) |
| `-32002` | `TASK_NOT_CANCELABLE` |
| `-32003` | `PUSH_NOTIFICATION_NOT_SUPPORTED` |
| `-32004` | `UNSUPPORTED_OPERATION` |
| `-32005` | `CONTENT_TYPE_NOT_SUPPORTED` |
| `-32006` | `INVALID_AGENT_RESPONSE` |
| `-32007` | `EXTENDED_AGENT_CARD_NOT_CONFIGURED` |
| `-32008` | `EXTENSION_SUPPORT_REQUIRED` |
| `-32009` | `VERSION_NOT_SUPPORTED` |
| `-32602` | `INVALID_PARAMS` |

Free-form failure detail travels in `ErrorInfo.metadata.detail` when
present; a payload already carrying an `ErrorInfo` is never double-wrapped
(registry source: `lib/ash_a2a/protocol/jsonrpc/error.ex`).

## Request payload rules (AshA2A specifics)

- **Skill selection**: set `message.metadata["skill"]` (atom-or-string via
  `AshA2A.MetadataKey`) to the skill `name` to dispatch. A resource/domain
  exposing exactly one skill dispatches implicitly with no metadata; two or
  more require it (`:ambiguous_skill` otherwise).
- **Input**: the caller's structured arguments are the message's
  `AshA2A.Protocol.Part.Data` part (`{"data": {...}}` — no `kind`
  discriminator; the decoder still accepts a v0.3-style `"kind"` field on
  input) — that map
  becomes the Ash action input. A text-only message dispatches with an
  empty input `%{}`. **File parts are not translated** — `Part.File`/
  `FileWithUri` are silently ignored by input extraction.
- **Streaming reads**: a Data part containing `"stream" => true` on a
  `:read` skill produces a lazy per-record stream (one `Part.Data` per
  record) instead of a materialized list.
- **Multi-turn**: `task_id`/`context_id` on the message thread conversation
  state; `context.history` reaches Ash actions as `context.a2a_history`.
  Pausing states pause the turn on the wire: an agent needing more from the
  caller ends the task in `TASK_STATE_INPUT_REQUIRED` (caller resends with
  the same `task_id`), and one needing credentials ends in
  `TASK_STATE_AUTH_REQUIRED` (the caller authenticates and resends);
  both are terminal for the current stream and resume only by a new
  message on the same task.

## Reply / task-state mapping

| Dispatch outcome | A2A task result |
| --- | --- |
| `{:reply, parts}` | artifact + task `:completed`. List results wrap as `%{"results": [...]}` in one `Part.Data`; scalars as `%{"result": value}`; maps pass through. |
| `{:input_required, parts}` | task `:input_required` (e.g. Ash `{:missing_argument, _}` errors, other caller-fixable `class: :invalid` errors). |
| `{:error, _}` | task `:failed`. |
| `{:stream, enumerable}` | streamed via `message/stream`. |

Resource/action wiring problems (`TenantRequired`, `NoPrimaryAction`)
surface as `{:error, {:invalid_config, _}}` task failures, not
`input_required`.

Direct dispatch (`AshA2A.Dispatcher.dispatch/6`) additionally guards
every skill through `AshA2A.CapabilityRelease.guard/2` before context
resolution (c846fac). In `:strict` mode a skill outside the frozen
released closure — including `:read` skills — fails with
`{:error, {:release_gate, {:capability_release_refused, ...}}}` (task
`:failed`); `:release_gate` is a stage in the dispatcher's stage-tagged
error tuples, between `:skill_lookup` and `:action_resolution`.

## Metadata merge order

Three layers, later wins: `:metadata` from plug init → `put_metadata/2`
on the conn (per-request) → `"metadata"` in the JSON-RPC params
(per-call). Auth identity is injected by the plug as
`metadata["a2a.auth"]` and is the **only** source of
`actor`/`tenant` inside dispatch — caller-supplied metadata never is.

## Authentication

Mount `AshA2A.Protocol.Plug.Auth` in front of `AshA2A.Protocol.Plug` (see
[the authentication how-to](../how-to/authenticate-agent-requests.md)).
Supported credential schemes: Bearer, HTTP Basic, API key
(header/query/cookie), OAuth2/OIDC bearer extraction — with **validation
100% delegated** to your `verify/3` callback (no JWKS, no introspection,
no signature checks; mTLS is declared-but-unsupported). Failures halt with
`401` + `%{"error" => "Unauthorized"}` (plus `WWW-Authenticate`); the
agent-card path is exempt by default.

Authentication is separate from authority: consequential
(`:change`/`:external_do`) skills additionally require a standing grant
(RFC-SA2A-001 S29).

## Operational limits to plan around

- **One mailbox per agent process** — a single `AshA2A.Protocol.Agent` GenServer
  serializes all its calls; throughput needs multiple agents or direct
  dispatch.
- **In-memory task store** — `tasks/get|cancel|list` see only tasks from
  the current process lifetime, single node.
- **Push notifications/webhooks (opt-in, owned transport only)** — with
  `push_notifications: true` and a running `AshA2A.A2ATransport`, each task
  status transition POSTs a wrapped v1.0 frame (`{"task": ...}`,
  `{"statusUpdate": ...}` or `{"artifactUpdate": ...}` — the same
  `StreamResponse` shapes the SSE stream emits, no JSON-RPC envelope) to
  every stored config's webhook URL (`AshA2A.A2ATransport.PushDelivery`):
  delivery is unordered — order with the `x-a2a-delivery-id` sequence header
  (`"<task_id>:<config_id>:<seq>"`, bounded exponential-backoff retries);
  every attempt re-admits the URL through `WebhookPolicy` and connects to the
  admitted IP (no redirects), and an optional `:signing_secret` adds
  `X-A2A-Timestamp`/`X-A2A-Signature` HMAC-SHA256 signing. Otherwise, poll
  `tasks/get` or use `message/stream` while connected.

## "Conformance" disambiguation

`priv/sa2a_conformance/` and the Chicago courts (`mix ash_a2a.sa2a_conformance`,
`mix ash_a2a.chicago`) are **semantic-law** conformance suites for the
SA2A pipeline — they are not A2A wire-protocol conformance tests. A2A
wire self-conformance is covered by the 25-court runner
`mix ash_a2a.v1_conformance_report` (see
[A2A v1.0 conformance statement](a2a-v1-conformance.md)); it is not the
official A2A TCK.
