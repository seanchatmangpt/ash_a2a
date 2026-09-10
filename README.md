# AshA2A

A `Spark.Dsl.Extension` that exposes `Ash.Resource`/`Ash.Domain` actions as
[A2A protocol](https://github.com/a2aproject/A2A) agent skills, on top of the
vendored [`:a2a`](https://github.com/a2aproject/a2a) Elixir SDK.

Declare an `a2a do skill ... end` block on a resource or domain, and AshA2A
compiles a verified capability index that:

- builds a real `A2A.AgentCard` (`AshA2A.Info.agent_card/2`) advertising each
  declared skill,
- fails closed at compile time (`AshA2A.Verify`) if a skill names a
  nonexistent action (`:REFUSED_ACTION_NOT_FOUND`) or duplicates a skill name
  (`:REFUSED_DUPLICATE_SKILL_NAME`),
- and dispatches an inbound `A2A.Message` to the right Ash action
  (`AshA2A.Dispatcher.dispatch/3`), either as a bare function call or through
  a real supervised `A2A.Agent` process (`AshA2A.Agent`).

## Installation

Add `ash_a2a` and the `:a2a` SDK to `mix.exs`:

```elixir
def deps do
  [
    {:ash_a2a, "~> 0.1.0"},
    {:a2a, "~> 0.1"}
  ]
end
```

## Usage

### 1. Declare the DSL on a resource (or domain)

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

`AshA2A.Transformers.BuildCapabilityIndex` compiles this into a persisted
`:ash_a2a_capability_index`, and `AshA2A.Verify` checks it (fail-closed) after
compilation. `AshA2A` may be used on a resource, a domain, or both.

### 2. Dispatch a message directly (no process)

```elixir
message = A2A.Message.new_user([A2A.Part.Data.new(%{})])

{:reply, [%A2A.Part.Data{data: %{results: []}}]} =
  AshA2A.Dispatcher.dispatch(:echo, message, MyApp.Echo)
```

### 3. Or run it as a real supervised A2A agent

```elixir
defmodule MyApp.EchoAgent do
  use AshA2A.Agent, resource_or_domain: MyApp.Echo, name: "echo_agent"
end
```

```elixir
children = [
  {A2A.AgentSupervisor, agents: [MyApp.EchoAgent]}
]

Supervisor.start_link(children, strategy: :one_for_one)

message = A2A.Message.new_user([A2A.Part.Data.new(%{})])
{:ok, task} = MyApp.EchoAgent.call(MyApp.EchoAgent, message)

task.status.state
#=> :completed
```

`AshA2A.Agent` builds the running process's `A2A.AgentCard` from the same
verified capability index `AshA2A.Info.agent_card/2` produces, and routes
every inbound message through `AshA2A.Dispatcher.dispatch/3` — the agent can
never advertise a skill dispatch can't actually serve. When a
resource/domain declares exactly one skill, the `metadata[:skill]` key on the
inbound `A2A.Message` may be omitted; with more than one skill, the caller
must set it to pick which one to dispatch.

Agents to boot with the app are read from application config by
`AshA2A.Application` (already wired as this app's `mod`):

```elixir
# config/config.exs
config :ash_a2a, :agents, [MyApp.EchoAgent]
```

See `test/support/fixture.ex` and `test/ash_a2a_test.exs` for a complete,
compiling, end-to-end example (including the fail-closed verifier paths)
exercised by the real test suite.

### 4. End-to-end over HTTP: serve the agent, call it with `A2A.Client`

The same `MyApp.EchoAgent` from step 3 is a real `A2A.Agent` GenServer, so it
can be served over HTTP with `A2A.Plug` (standalone under `Bandit`, or
`forward`ed into a Phoenix router) and driven from a separate process with
`A2A.Client` — a full round trip over JSON-RPC, not a direct BEAM call.

`A2A.Plug` and `A2A.Client` are conditionally compiled by `:a2a` itself
(`Code.ensure_loaded?(Plug)` / `Code.ensure_loaded?(Req)`), so add whichever
optional HTTP deps your app needs on top of `ash_a2a`/`a2a`:

```elixir
def deps do
  [
    {:ash_a2a, "~> 0.1.0"},
    {:a2a, "~> 0.1"},
    {:bandit, "~> 1.5"},
    {:plug, "~> 1.16"},
    {:req, "~> 0.5"}
  ]
end
```

Start the agent under a supervisor together with `A2A.Plug`/`Bandit` serving
it at `/a2a`:

```elixir
children = [
  {A2A.AgentSupervisor, agents: [MyApp.EchoAgent]},
  {Bandit,
   plug: {A2A.Plug, agent: MyApp.EchoAgent, base_url: "http://localhost:4000/a2a"},
   port: 4000}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

From a client (a different node, a test, or a plain `iex -S mix` shell),
discover the agent card and send it a message with `A2A.Client` — nothing
about `MyApp.EchoAgent`'s module or the Ash resource behind it is required,
only the URL:

```elixir
{:ok, card} = A2A.Client.discover("http://localhost:4000/a2a")
card.name #=> "echo_agent"

client = A2A.Client.new(card)

{:ok, task} =
  A2A.Client.send_message(client, A2A.Message.new_user([A2A.Part.Data.new(%{})]))

task.status.state
#=> :completed
```

`A2A.Client.discover/2` fetches `GET /a2a/.well-known/agent-card.json`
(served by `A2A.Plug` from the exact same verified capability index as steps
1–3), and `A2A.Client.send_message/3` posts `message/send` over JSON-RPC to
the same `A2A.Plug` mount. `A2A.Plug` forwards the decoded `A2A.Message` into
`MyApp.EchoAgent`'s GenServer, which routes it through
`AshA2A.Agent.__dispatch__/3` into `AshA2A.Dispatcher.dispatch/3` — the exact
same dispatch path as the in-process `call/2` in step 3, just carried over
HTTP instead of a direct BEAM message.

## Installer

`mix ash_a2a.install` (an Igniter task) wires the extension into a project;
see `lib/mix/tasks/ash_a2a.install.ex`.

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm).
