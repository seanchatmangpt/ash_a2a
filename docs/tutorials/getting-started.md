# Getting Started

This tutorial builds one Ash resource, exposes it as an A2A agent skill, and
calls it two ways: a direct dispatch (no process) and a real supervised
`AshA2A.Agent`. By the end you'll have a working agent you can send a message
to and get a reply from.

It follows the real code in `test/support/fixture.ex` and
`test/ash_a2a_test.exs` — every step below matches a genuine, compiling
example already exercised by this project's own test suite.

## Prerequisites

Add `ash_a2a` and the vendored `:a2a` SDK to your `mix.exs`:

```elixir
def deps do
  [
    {:ash_a2a, "~> 26.9"},
    {:a2a, "~> 0.2"}
  ]
end
```

You'll also need an `Ash.Resource` and `Ash.Domain` — this tutorial defines
both from scratch.

## 1. Declare the DSL on a resource

Create a resource, add `AshA2A` to its `extensions:` list, and declare one
`a2a do skill(...) end` block naming the skill and the Ash action it wraps:

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

`AshA2A` can be used on the resource, the domain, or both — here it's on the
resource, and the domain just needs the plain `resources do ... end` block to
list it.

When this compiles, `AshA2A.Transformers.BuildCapabilityIndex` builds a
persisted `:ash_a2a_capability_index` for `MyApp.Echo`, and `AshA2A.Verify`
checks it fail-closed right after compilation — if `skill(:echo, :read)` had
named an action that doesn't exist on `MyApp.Echo`, compilation would abort
with `:REFUSED_ACTION_NOT_FOUND` rather than silently deferring the failure
to runtime.

You can confirm the skill compiled by asking `AshA2A.Info` for it:

```elixir
AshA2A.Info.capability_index?(MyApp.Echo)
#=> true

AshA2A.Info.capability_index(MyApp.Echo)
#=> [%AshA2A.Skill{id: "MyApp.Echo.read", name: :echo, resource: MyApp.Echo, action: :read}]
```

## 2. Dispatch a message directly (no process)

With the capability index compiled, you can dispatch an inbound `A2A.Message`
straight to the resource — no agent process required:

```elixir
message = A2A.Message.new_user([A2A.Part.Data.new(%{})])

{:reply, [%A2A.Part.Data{data: %{results: []}}]} =
  AshA2A.Dispatcher.dispatch(:echo, message, MyApp.Echo)
```

`AshA2A.Dispatcher.dispatch/3` takes the skill name, the `A2A.Message`, and
the resource (or domain) the capability index was compiled on. It runs the
underlying `:read` action for real through Ash and wraps the result back into
an `A2A.Part.Data` reply — there's no separate "A2A layer" logic re-deriving
what the action does; the dispatcher just runs the real action.

## 3. Wrap it as a supervised A2A agent

A bare `dispatch/3` call is synchronous and process-free. To run the same
resource as a long-lived, addressable agent, define a module with
`use AshA2A.Agent`:

```elixir
defmodule MyApp.EchoAgent do
  use AshA2A.Agent, resource_or_domain: MyApp.Echo, name: "echo_agent"
end
```

Start it under a real `A2A.AgentSupervisor` and call it:

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

`AshA2A.Agent` builds the running process's `A2A.AgentCard` from the exact
same verified capability index that `AshA2A.Info.agent_card/2` produces, and
routes every inbound message through the `AshA2A.Dispatcher.dispatch/3` you
just called directly in step 2 — the agent can never advertise a skill that
dispatch can't actually serve. Because `MyApp.Echo` declares only one skill,
the inbound message's `metadata[:skill]` may be omitted; a resource or domain
with more than one skill requires the caller to set it, to say which skill to
dispatch.

To boot agents automatically with your app, list them in config for
`AshA2A.Application` (already wired as this project's OTP `mod`):

```elixir
# config/config.exs
config :ash_a2a, :agents, [MyApp.EchoAgent]
```

## What you built, and what's next

You now have: a real Ash resource with an `a2a do skill(...) end` block, a
verified capability index checked fail-closed at compile time, a working
direct dispatch call, and a supervised `AshA2A.Agent` process you called with
`Agent.call/2` end to end.

From here, the how-to guides cover specific problems you'll hit next:
handling actions that take arguments or mutate data (`:create`/`:update`/
`:destroy` skills, not just `:read`), resolving LLM-backed actions to a
provider by role instead of hardcoding one (`AshA2A.LLMProfiles`), and how
`AshA2A.Authority`/`AshA2A.CommandBus` admission and receipting works (as of
v26.9.14 this is the automatic default route for any `:change`/
`:external_do` skill your resource declares -- there's nothing extra to wire
in for the common case). See `docs/how-to/` and
[Architecture](../explanation/architecture.md) for those, and
`test/support/fixture.ex` for further real, compiling fixture resources
covering each of those shapes.
