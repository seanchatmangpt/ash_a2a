# Getting Started

This tutorial builds one Ash resource, exposes it as an A2A agent skill,
and calls it three ways: a direct dispatch (no process), a real supervised
`AshA2A.Agent`, and finally over HTTP as a served A2A endpoint driven by
`AshA2A.Protocol.Client`. By the end you'll have a working agent you can send a message
to and get a reply from, on and off the network.

Every step below matches genuine, compiling code already exercised by this
project's own test suite (the resource shapes come from
`test/support/fixture.ex`; in a Hex-installed app you will write your own —
the snippets here are self-contained).

## Prerequisites

Add `ash_a2a` to your `mix.exs` (the `AshA2A.Protocol.*` wire codec ships
inside the package — no separate protocol dependency):

```elixir
def deps do
  [
    {:ash_a2a, "~> 26.10.3"}
  ]
end
```

You'll also need an `Ash.Resource` and `Ash.Domain` — this tutorial defines
both from scratch. `mix ash_a2a.install` (an Igniter task) can wire the
extension into an existing project for you.

## 1. Declare the DSL on a resource

Create a resource and add `AshA2A` to its `extensions:` list:

```elixir
defmodule MyApp.Echo do
  use Ash.Resource,
    domain: MyApp.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:message, :string, public?: true)
  end

  actions do
    defaults([:read])
  end

  a2a do
    skill(:echo, :read)
  end
end

defmodule MyApp.Domain do
  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(MyApp.Echo)
  end
end
```

`AshA2A` can be used on the resource, the domain, or both — here it's on
the resource, and the domain just needs the plain `resources do ... end`
block to list it.

Two facts about what you just declared:

- **Public actions are the capability surface.** Since v26.9.12 every
  *public* Ash action on an extended resource/domain is exposed as a skill
  with no declaration at all; the `a2a do skill(:echo, :read) end` block is
  an optional override (display name, description, tags, exclusion,
  consequence classification) — it cannot manufacture a capability for an
  action that doesn't exist.
- **Compilation is fail-closed.** `AshA2A.Transformers.BuildCapabilityIndex`
  persists the residual overrides (and the semantic-requests flag), the
  capability index itself is derived from
  `Ash.Resource.Info.public_actions/1`, and `AshA2A.Verify` checks the
  result right after compilation — a skill override naming a nonexistent
  action aborts compilation with `:REFUSED_ACTION_NOT_FOUND` rather than
  deferring the failure to runtime.

You can confirm the skill compiled by asking `AshA2A.Info` for it:

```elixir
AshA2A.Info.capability_index?(MyApp.Echo)
#=> true

AshA2A.Info.capability_index(MyApp.Echo)
#=> [%AshA2A.Skill{id: "MyApp.Echo.read", name: :echo, resource: MyApp.Echo, action: :read, ...}]
```

## 2. Dispatch a message directly (no process)

With the capability index compiled, you can dispatch an inbound `AshA2A.Protocol.Message`
straight to the resource — no agent process required:

```elixir
message = AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(%{})])

{:reply, [%AshA2A.Protocol.Part.Data{data: %{results: []}}]} =
  AshA2A.Dispatcher.dispatch(:echo, message, MyApp.Echo)
```

`AshA2A.Dispatcher.dispatch/6` takes the skill name, the `AshA2A.Protocol.Message`, and
the resource (or domain), plus optional `history` and `auth_identity`
arguments (both default to `nil`). It runs the underlying `:read` action
for real through Ash and wraps the result back into an `AshA2A.Protocol.Part.Data`
reply — there's no separate "A2A layer" logic re-deriving what the action
does; the dispatcher just runs the real action. Note that `auth_identity`
defaulting to `nil` is the trust boundary: identity only ever arrives from
transport-verified auth, never from message metadata (see
[Authenticate inbound A2A requests](../how-to/authenticate-agent-requests.md)).

## 3. Run it as a supervised A2A agent

A bare `dispatch/6` call is synchronous and process-free. To run the same
resource as a long-lived, addressable agent, define a module with
`use AshA2A.Agent`:

```elixir
defmodule MyApp.EchoAgent do
  use AshA2A.Agent,
    resource_or_domain: MyApp.Echo,
    name: "echo_agent",
    # read-only quickstart: let identity-less callers reach the :echo skill
    require_authenticated_caller: false
end
```

By default `use AshA2A.Agent` requires an authenticated caller: with no
identity, dispatch is refused `%{code: :unauthenticated}` before any skill
runs. The quickstart's echo is a read-only skill with no actor-dependent
behavior, so it opts out explicitly; production agents keep the default and
wire real credentials (see
[Authenticate inbound A2A requests](../how-to/authenticate-agent-requests.md)).

The simplest way to boot it is config: `ash_a2a` ships its own OTP
application (`AshA2A.Application`) whose supervision tree already starts an
`AshA2A.Protocol.AgentSupervisor` under global names — so you register agents with it
rather than starting a second supervisor:

```elixir
# config/config.exs
config :ash_a2a, :agents, [MyApp.EchoAgent]
```

Restart your app, then call the agent:

```elixir
message = AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(%{})])
{:ok, task} = MyApp.EchoAgent.call(MyApp.EchoAgent, message)

task.status.state
#=> :completed
```

(If you need to start an agent outside the library's supervisor tree —
e.g. in tests — start the module directly with
`MyApp.EchoAgent.start_link([])`. Starting a *second*
`AshA2A.Protocol.AgentSupervisor` with default names raises `:already_started`,
because `AshA2A.Application` already runs one.)

`AshA2A.Agent` builds the running process's `AshA2A.Protocol.AgentCard` from the exact
same verified capability index that `AshA2A.Info.agent_card/2` produces, so
the agent can never advertise a skill dispatch can't actually serve.
Because `MyApp.Echo` exposes exactly one public action, the inbound
message's `metadata[:skill]` may be omitted; a resource or domain with more
than one skill requires the caller to set it, to say which skill to
dispatch. Routing is by compiled consequence classification: `:observe`
skills (like this `:read`) go straight to `Dispatcher.dispatch/6`, while
`:change`/`:external_do` skills route through the receipted
`AshA2A.CommandBus` (authority admission, replay-safe receipts) — see
[Architecture](../explanation/architecture.md).

## 4. Serve it over HTTP and call it with `AshA2A.Protocol.Client`

An `AshA2A.Agent` module is a real `AshA2A.Protocol.Agent` GenServer, so
`AshA2A.Protocol.Plug` can serve it directly. Add a web server to your app (here
Bandit; `AshA2A.Protocol.Plug` is a standard Plug, so a Phoenix `forward "/a2a",
AshA2A.Protocol.Plug, ...` works the same way):

```elixir
# mix.exs
{:bandit, "~> 1.5"}

# your Application's children
children = [
  {Bandit, plug: {AshA2A.Protocol.Plug, agent: MyApp.EchoAgent, base_url: "http://localhost:4000"}}
]
```

Fetch the agent card — the capability index, projected to the wire:

```sh
curl http://localhost:4000/.well-known/agent-card.json
# ... "skills": [{"id": "MyApp.Echo.read", "name": "echo", ...}]
```

Send a message over JSON-RPC (parts carry no `kind` discriminator — a data
part is just `{"data": {...}}`):

```sh
curl -X POST http://localhost:4000/ \
  -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"message/send",
       "params":{"message":{"messageId":"m-1","role":"user",
                            "parts":[{"data":{}}]}}}'
# {"jsonrpc":"2.0","id":1,"result":{"task":{"id":"...","contextId":"...",
#  "status":{"state":"TASK_STATE_COMPLETED"},...}}}
```

The `message/send` result wraps the task under a `"task"` key (a Message
reply would wrap under `"message"` — the v1.0 `SendMessageResponse` oneof).
Streaming uses the same v1.0 wire shapes: `message/stream` answers with SSE
frames wrapped in `StreamResponse` envelopes — `{"task": ...}`,
`{"statusUpdate": ...}`, `{"artifactUpdate": ...}` — and no `final`
boolean; the stream simply ends once the task reaches a terminal state.

Serve streaming through the owned `AshA2A.A2ATransport.Plug` (a supervised
wrapper around the bare plug). Do not route `message/stream` at the bare
`AshA2A.Protocol.Plug` alone: an `AshA2A.Agent`'s card declares
`streaming: true` by default, so the bare plug accepts the method and then
answers `-32603` with `data` `{:not_streaming, task}` when the agent
process returns a task with no stream attached. `AshA2A.A2ATransport.Plug`
attaches a real SSE stream for every skill.

### Choose a transport binding

Both bindings serve the same agent; pick by client. JSON-RPC 2.0
(`AshA2A.Protocol.Plug` / `AshA2A.A2ATransport.Plug`, the `POST /` above)
is the established wire shape with the wider tooling; the v1.0 HTTP+JSON
binding (`AshA2A.Transport.HTTPJSON`) is the spec's native REST shape —
mount it as a sibling plug:

```elixir
plug AshA2A.Transport.HTTPJSON,
  agent: MyApp.EchoAgent, base_url: "http://localhost:4000"
```

Sending a message is `POST /message:send` with a `MessageSendParams` body
— the same flat v1.0 part shapes as JSON-RPC (a text part is just
`{"text": ...}`, no `kind` discriminator), and no `{"task": ...}` wrapper
in the reply:

```sh
curl -X POST http://localhost:4000/message:send \
  -H 'content-type: application/json' \
  -d '{"message":{"messageId":"m-1","role":"user",
       "parts":[{"text":"hello"}]}}'
# 200 {"id":"tsk-...","contextId":"...","status":{"state":"TASK_STATE_COMPLETED"}}
```

Read the task back with `GET /tasks/{id}` and cancel it with
`POST /tasks/{id}:cancel` — cancelling a task that already reached a
terminal state answers `409` with a `google.rpc.ErrorInfo` payload
(`reason: "TASK_NOT_CANCELABLE"`, domain `a2a-protocol.org`).

Or drive it from Elixir with `AshA2A.Protocol.Client` (requires the `:req` package):

```elixir
{:ok, card} = AshA2A.Protocol.Client.discover("http://localhost:4000")
client = AshA2A.Protocol.Client.new(card)

{:ok, task} = AshA2A.Protocol.Client.send_message(client, "hello")
task.status.state
#=> :completed
```

The full endpoint surface — methods, error codes, SSE streaming via
`message/stream`, auth wiring, and the exact metadata rules — is in the
[A2A endpoint reference](../reference/a2a-endpoint-contract.md).

If the serving agent signs its card (`AshA2A.Protocol.CardSigning.sign/3`
server-side), verify that signature before trusting a discovered card:

```elixir
{:ok, card} = AshA2A.Protocol.Client.discover("http://localhost:4000")

:ok = AshA2A.Protocol.CardSigning.verify(card, signing_key)
```

`CardSigning.verify/3` returns `:ok` when every `signatures` JWS entry
verifies against the JCS canonicalization of the card payload, otherwise
`{:error, {:bad_signature | :digest_mismatch | :malformed, detail}}` for
the first failing entry.

## What you built, and what's next

You now have: a real Ash resource whose public actions are projected into
a verified capability index, a working direct dispatch call, a supervised
`AshA2A.Agent` process, and an HTTP-served A2A endpoint exercised both by
raw JSON-RPC and by `AshA2A.Protocol.Client`.

From here, the how-to guides cover specific problems you'll hit next:
handling actions that take arguments or mutate data (`:create`/`:update`/
`:destroy` skills — the consequential ones route through
`AshA2A.CommandBus` with authority grants automatically), wiring
authentication so `context.actor`/`context.tenant` are real
([Authenticate inbound A2A requests](../how-to/authenticate-agent-requests.md)),
resolving LLM-backed actions to a provider by role
([Use role-based LLM resolution](../how-to/use-role-based-llm-resolution.md)),
and observing dispatch with OCEL
([Observe dispatch with OCEL](../how-to/observe-dispatch-with-ocel.md)). For
how the pieces fit together, read
[Architecture](../explanation/architecture.md) and
[Message lifecycle](../explanation/message-lifecycle.md).
