# How to choose a reply mode

Status: the behavior below is exercised by the `ping` probes of
`mix ash_a2a.sim --prove` ("message/send answers a bare Message on every
binding and stores no task" and "a stream is exactly one Message frame on every
binding and stores no task"), which passed on 2026-11-17 (243 probes, 0 failures).
`test/ash_a2a_transport_grpc_server_test.exs` covers the gRPC side.

A2A v1.1 section 3.1.2 allows two answers to a message: a **Task** (stored,
addressable by id, with a lifecycle) or a bare **Message** (nothing stored). An
agent declares which one it gives, and the declaration decides what
`message/stream` does, because the first frame of a stream commits the server to
one shape.

## Declare it on a skill

For an agent built with `use AshA2A.Agent`, set `reply` in the `a2a` DSL:

```elixir
a2a do
  skill :ping, :ping do
    consequence :observe
    reply :message
  end
end
```

`reply` takes `:task` (the default) or `:message`. A `reply :message` skill:

- answers `message/send` with a bare Message that carries the action's result;
- answers `message/stream` with exactly one Message frame, then closes the stream;
- stores no task, so there is nothing to `GetTask`, `CancelTask` or resubscribe to;
- cannot ask for input, stream artifacts or be cancelled;
- still answers with a task when it is refused (authority, validation), so the
  refusal has somewhere to live.

Every other skill of the same agent keeps the task lifecycle.

## Declare it on a hand-written agent

For `use AshA2A.Protocol.Agent`, the `:reply` option applies to the whole agent:

```elixir
use AshA2A.Protocol.Agent, reply: :message   # every message gets a bare Message
use AshA2A.Protocol.Agent, reply: :task      # every message gets a task, admitted first
use AshA2A.Protocol.Agent                    # undeclared
```

Undeclared is the one case where the handler runs before the shape is known: a
`{:message, parts}` reply is a message-only stream, and any other reply opens the
task stream once the handler has returned. The task is therefore not stored
before the work starts. Declare `reply: :task` when a client needs the task id
while the work is in flight.

To decide per message, override `reply_mode/1` (a callback of
`AshA2A.Protocol.Agent`). It receives the `AshA2A.Protocol.Message` and returns
`:task`, `:message` or `:undeclared`. For `use AshA2A.Agent` the generated
`reply_mode/1` reads the skill's `reply` declaration through `AshA2A.Info.skill/2`.

## See the difference

Start the simulation server (`mix ash_a2a.sim --http-port 4190`); its `ping`
skill is `reply :message` and `count_notes` is not. Sending `ping` over HTTP+JSON:

```console
$ curl -s http://127.0.0.1:4190/rest/message:send \
    -H 'authorization: Bearer sim-writer-token' -H 'a2a-version: 1.1' \
    -H 'content-type: application/json' \
    -d '{"message":{"messageId":"m-p1","role":"ROLE_USER","parts":[{"data":{}}],"metadata":{"skill":"ping"}}}'
{"message":{"contextId":"ctx-u4YzBq5NkgFtVnRl4C73uw","messageId":"msg-4aLtcG9sgEOR","parts":[{"data":{"pong":"pong"}}],"role":"ROLE_AGENT"}}
```

The same message to `/rest/message:stream` is one frame:

```console
data: {"message":{"contextId":"ctx-8OdzzSS05MOxayGJVt_Asg","messageId":"msg-p1NfF79UPHQq","parts":[{"data":{"pong":"pong"}}],"role":"ROLE_AGENT"}}
```

`count_notes` streams the task lifecycle: a `task` frame first, then an
`artifactUpdate` (with `lastChunk: true`), then a `statusUpdate` to
`TASK_STATE_COMPLETED`.

## Changed behavior

Before this release a skill that did not chunk its output answered `message/stream`
with `-32004`. Now every skill answers a stream. A bare-Message agent that relied
on the old behavior must declare `reply: :message` (or `reply :message` on the
skill) to keep a single Message frame; without a declaration, a `use AshA2A.Agent`
skill streams the task lifecycle. See the CHANGELOG entry under Breaking.

See also [v1.1 live and generations](v1-1-live-and-generations.md) for the stream
patterns in context.
