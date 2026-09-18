# A2A Endpoint Reference

The exact HTTP surface an AshA2A-served agent exposes, per the vendored
`:a2a` SDK (`deps/a2a/lib/a2a/plug.ex`, `jsonrpc.ex`, `jsonrpc/error.ex`).
Protocol level: **A2A v0.3, JSON-RPC 2.0 over HTTP POST**, with SSE
streaming for `message/stream`. The gRPC binding is not implemented, and
push notifications/webhooks are explicitly unsupported.

## Endpoints

`A2A.Plug` is mounted with `agent:` and `base_url:` options (see the
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
the `:base_url` option or `A2A.Plug.put_base_url/2` in an upstream
plug/pipeline. Note the card builder's own URL default is
`http://localhost:4000` (`AshA2A.CapabilityIndex.AgentCardBuilder`), so a
production deployment must always set it.

## Agent card

`AshA2A.Info.agent_card/2` projects the compiled capability index
(`AshA2A.CapabilityIndex.AgentCardBuilder.build_agent_card/2`) into an
`A2A.AgentCard`:

- `name` (default `"ash_a2a_agent"`), `description`, `version` (default
  `"0.1.0"`), `provider` — overridable via card opts.
- `skills`, sorted by id; per skill: `id` = `"<Resource>.<action>"`,
  `name` = override or the action name, `description` = override or derived
  from the real Ash action's description/type/arguments, `tags` = override
  or `[action.type | argument names]`.
- `default_input_modes`/`default_output_modes` are the SDK's
  `["text/plain"]` default — note the dispatch contract below actually
  exchanges structured `Part.Data` (JSON) content.
- `supported_interfaces` defaults to
  `%{url: url, protocol_binding: "JSONRPC", protocol_version: "0.3.0"}`.

## JSON-RPC methods

| Method | Behavior |
| --- | --- |
| `message/send` | Synchronous dispatch; result is an A2A task object. |
| `message/stream` | SSE streaming response (`text/event-stream`): initial task snapshot, then per-part events, final `StatusUpdate` with `final: true`. |
| `tasks/get` / `tasks/cancel` / `tasks/list` | Task management within the agent process's lifetime (the task store is in-memory ETS, single node). |
| `tasks/resubscribe` | Unsupported → `-32004`. |
| `tasks/pushNotificationConfig/*` | Unsupported → `-32003`. |
| anything else | `-32601` method not found. |

## Error codes

`-32700` parse error · `-32600` invalid request · `-32601` method not
found · `-32602` invalid params · `-32603` internal error · `-32001` task
not found · `-32002` task not cancelable · `-32003` push notification not
supported · `-32004` unsupported operation (also
`agent/getAuthenticatedExtendedCard`).

## Request payload rules (AshA2A specifics)

- **Skill selection**: set `message.metadata["skill"]` (atom-or-string via
  `AshA2A.MetadataKey`) to the skill `name` to dispatch. A resource/domain
  exposing exactly one skill dispatches implicitly with no metadata; two or
  more require it (`:ambiguous_skill` otherwise).
- **Input**: the caller's structured arguments are the message's
  `A2A.Part.Data` part (`{"kind": "data", "data": {...}}`) — that map
  becomes the Ash action input. A text-only message dispatches with an
  empty input `%{}`. **File parts are not translated** — `Part.File`/
  `FileWithUri` are silently ignored by input extraction.
- **Streaming reads**: a Data part containing `"stream" => true` on a
  `:read` skill produces a lazy per-record stream (one `Part.Data` per
  record) instead of a materialized list.
- **Multi-turn**: `task_id`/`context_id` on the message thread conversation
  state; `context.history` reaches Ash actions as `context.a2a_history`.

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

## Metadata merge order

Three layers, later wins: `:metadata` from plug init → `put_metadata/2`
on the conn (per-request) → `"metadata"` in the JSON-RPC params
(per-call). Auth identity is injected by the plug as
`metadata["a2a.auth"]` and is the **only** source of
`actor`/`tenant` inside dispatch — caller-supplied metadata never is.

## Authentication

Mount `A2A.Plug.Auth` in front of `A2A.Plug` (see
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

- **One mailbox per agent process** — a single `A2A.Agent` GenServer
  serializes all its calls; throughput needs multiple agents or direct
  dispatch.
- **In-memory task store** — `tasks/get|cancel|list` see only tasks from
  the current process lifetime, single node.
- **No push notifications** — poll `tasks/get` or use
  `message/stream` while connected.

## "Conformance" disambiguation

`priv/sa2a_conformance/` and the Chicago courts (`mix ash_a2a.sa2a_conformance`,
`mix ash_a2a.chicago`) are **semantic-law** conformance suites for the
SA2A pipeline — they are not A2A wire-protocol conformance tests. No A2A
protocol conformance suite ships with this repo.
