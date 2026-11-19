# v1-1-live-and-generations

Standing: PARTIAL

How to use the A2A v1.1 live stream, task generations and optimistic concurrency
against an ash_a2a agent. Row-level courts: [A2A v1.1 conformance](../reference/a2a-v1-1-conformance.md).
Select v1.1 with the `A2A-Version: 1.1` header.

## Read generation and timeline

Every task carries `generation` (monotonic integer) and `timeline[]`. Truncate the
timeline with `timelineLength`.

```bash
curl -H 'A2A-Version: 1.1' "$BASE/tasks/$ID?timelineLength=5"
```

## Long poll for the next generation

Pass the generation you already hold. The server parks until the task advances, is
terminal, or `config :ash_a2a, :long_poll_timeout_ms` (default 30_000) elapses.

```bash
curl -H 'A2A-Version: 1.1' "$BASE/tasks/$ID?currentGeneration=3"
```

## Guard a send with ifGenerationMatch

Set `configuration.ifGenerationMatch` on `SendMessage`. A stale value is JSON-RPC
`-32010` (`TASK_GENERATION_MISMATCH`) or HTTP 409 with status `ABORTED`; re-read the
task and retry.

```json
{"message": {"taskId": "T1"}, "configuration": {"ifGenerationMatch": 3}}
```

## Stream patterns: message-only and task lifecycle

`SendStreamingMessage` has two valid shapes (specification 3.1.2), and the first
frame commits the server to one of them:

- **Task lifecycle stream** (the default). The stream is admitted first: the Task
  is stored and sent as the first frame before the skill runs, so its id works with
  `GetTask` and `CancelTask` while the work is in flight. One event per stored
  mutation follows, each at the task's generation, until the task is terminal or
  interrupted. A quiet handler does not end the stream; SSE bindings write a
  `: keepalive` comment every `config :ash_a2a, :stream_tick_ms` (15 s).
- **Message-only stream**. Exactly one Message frame, then the stream closes. No
  task is admitted or stored, and `SendMessage` answers the same bare Message.

Which one a message gets is declared before the handler runs:

| Agent | Declaration | Stream |
| --- | --- | --- |
| `use AshA2A.Agent` | skill option `reply :message` in the `a2a` DSL | message-only for that skill; task lifecycle for every other skill |
| `use AshA2A.Protocol.Agent, reply: :message` | the whole agent | message-only |
| `use AshA2A.Protocol.Agent, reply: :task` | the whole agent | task lifecycle, admitted first |
| `use AshA2A.Protocol.Agent` (no `:reply`) | undeclared | the handler runs first: a `{:message, parts}` reply is a message-only stream, anything else opens the task stream once the handler has returned |

Override `reply_mode/1` on the agent to decide per message.

```elixir
a2a do
  skill :ping, :ping do
    consequence :observe
    reply :message
  end
end
```

A `reply :message` skill cannot ask for input, stream artifacts or be cancelled. If
it is refused (authority, validation) the answer is a task after all, carrying the
refusal.

## Live stream

`POST /message:live` (HTTP+JSON) and gRPC `SendLiveMessage` open an SSE downlink whose
first frame is a Task snapshot. The agent card must declare `capabilities.streaming`.
JSON-RPC has no live method. A `StreamRequest` naming a different task yields a
`StreamError` frame and the stream stays open.

## Resume a subscription

`SubscribeToTask` with `lastSeenGeneration=N` skips the snapshot and sends only newer
events. If the generation cannot be replayed, the server sends a snapshot. A
non-integer value is `-32602`.

```bash
curl -N -H 'A2A-Version: 1.1' "$BASE/tasks/$ID:subscribe?lastSeenGeneration=7"
```

## Write artifacts as a client

Declare `transport do user_artifacts true end` on the domain; the card then advertises
`capabilities.userArtifacts` and `SendMessageRequest.artifactUpdates` is accepted.
Without it, `artifactUpdates` answers `-32004`.

## Related configuration

- `config :ash_a2a, :events_transport` (or `execution: [events_transport: name]`):
  publishes `messageUpdate` events.
- `execution: [cancel_in_flight: :refuse]`, `execution: [validate_input_modes: false]`.

Details: [configuration](../reference/configuration.md).

## See Also

- [Endpoint contract](../reference/a2a-endpoint-contract.md)
- [Spec-version mapping](../reference/a2a-spec-version-mapping.md)
- [A2A v1.1 conformance](../reference/a2a-v1-1-conformance.md)
