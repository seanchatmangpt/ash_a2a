# Getting Started

This tutorial builds one Ash resource, exposes it as an A2A agent skill,
and calls it three ways: a direct dispatch (no process), a real supervised
`AshA2A.Agent`, and finally over HTTP as a served A2A endpoint driven by
`A2A.Client`. By the end you'll have a working agent you can send a message
to and get a reply from, on and off the network.

Every step below matches genuine, compiling code already exercised by this
project's own test suite (the resource shapes come from
`test/support/fixture.ex`; in a Hex-installed app you will write your own —
the snippets here are self-contained).

## Prerequisites

Add `ash_a2a` to your `mix.exs` (the `:a2a` SDK arrives transitively; pin
it only if you call `A2A.*` yourself):

```elixir
def deps do
  [
    {:ash_a2a, "~> 26.9"}
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

With the capability index compiled, you can dispatch an inbound `A2A.Message`
straight to the resource — no agent process required:

```elixir
message = A2A.Message.new_user([A2A.Part.Data.new(%{})])

{:reply, [%A2A.Part.Data{data: %{results: []}}]} =
  AshA2A.Dispatcher.dispatch(:echo, message, MyApp.Echo)
```

`AshA2A.Dispatcher.dispatch/6` takes the skill name, the `A2A.Message`, and
the resource (or domain), plus optional `history` and `auth_identity`
arguments (both default to `nil`). It runs the underlying `:read` action
for real through Ash and wraps the result back into an `A2A.Part.Data`
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
  use AshA2A.Agent, resource_or_domain: MyApp.Echo, name: "echo_agent"
end
```

The simplest way to boot it is config: `ash_a2a` ships its own OTP
application (`AshA2A.Application`) whose supervision tree already starts an
`A2A.AgentSupervisor` under global names — so you register agents with it
rather than starting a second supervisor:

```elixir
# config/config.exs
config :ash_a2a, :agents, [MyApp.EchoAgent]
```

Restart your app, then call the agent:

```elixir
message = A2A.Message.new_user([A2A.Part.Data.new(%{})])
{:ok, task} = MyApp.EchoAgent.call(MyApp.EchoAgent, message)

task.status.state
#=> :completed
```

(If you need to start an agent outside the library's supervisor tree —
e.g. in tests — start the module directly with
`MyApp.EchoAgent.start_link([])`. Starting a *second*
`A2A.AgentSupervisor` with default names raises `:already_started`,
because `AshA2A.Application` already runs one.)

`AshA2A.Agent` builds the running process's `A2A.AgentCard` from the exact
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

## 4. Serve it over HTTP and call it with `A2A.Client`

An `AshA2A.Agent` module is a real `A2A.Agent` GenServer, so the SDK's
`A2A.Plug` can serve it directly. Add a web server to your app (here
Bandit; `A2A.Plug` is a standard Plug, so a Phoenix `forward "/a2a",
A2A.Plug, ...` works the same way):

```elixir
# mix.exs
{:bandit, "~> 1.5"}

# your Application's children
children = [
  {Bandit, plug: {A2A.Plug, agent: MyApp.EchoAgent, base_url: "http://localhost:4000"}}
]
```

Fetch the agent card — the capability index, projected to the wire:

```sh
curl http://localhost:4000/.well-known/agent-card.json
# ... "skills": [{"id": "MyApp.Echo.read", "name": "echo", ...}]
```

Send a message over JSON-RPC (A2A v0.3 wire format):

```sh
curl -X POST http://localhost:4000/ \
  -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"message/send",
       "params":{"message":{"messageId":"m-1","role":"user",
                            "parts":[{"kind":"data","data":{}}]}}}'
# {"jsonrpc":"2.0","id":1,"result":{"kind":"task",...,"status":{"state":"completed"},...}}
```

Or drive it from Elixir with `A2A.Client` (requires the `:req` package):

```elixir
{:ok, card} = A2A.Client.discover("http://localhost:4000")
client = A2A.Client.new(card)

{:ok, task} = A2A.Client.send_message(client, "hello")
task.status.state
#=> :completed
```

The full endpoint surface — methods, error codes, SSE streaming via
`message/stream`, auth wiring, and the exact metadata rules — is in the
[A2A endpoint reference](../reference/a2a-endpoint-contract.md).

## What you built, and what's next

You now have: a real Ash resource whose public actions are projected into
a verified capability index, a working direct dispatch call, a supervised
`AshA2A.Agent` process, and an HTTP-served A2A endpoint exercised both by
raw JSON-RPC and by `A2A.Client`.

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
