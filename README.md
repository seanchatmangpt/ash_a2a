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
    {:ash_a2a, "~> 26.9"},
    {:a2a, "~> 0.1"}
  ]
end
```

## Usage

Declare the DSL on a resource (or domain):

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

Dispatch a message directly (no process):

```elixir
message = A2A.Message.new_user([A2A.Part.Data.new(%{})])

{:reply, [%A2A.Part.Data{data: %{results: []}}]} =
  AshA2A.Dispatcher.dispatch(:echo, message, MyApp.Echo)
```

For the full walkthrough — running a supervised `A2A.Agent` process, serving
it over HTTP with `A2A.Plug`/`A2A.Client`, and role-based LLM provider
resolution — see the [Getting Started tutorial](docs/tutorials/getting-started.md).

## Documentation

This project follows the [Diataxis](https://diataxis.fr/) documentation
framework: tutorials for learning, how-to guides for specific tasks,
reference for lookup, and explanation for understanding.

- **Tutorials** — [Getting Started](docs/tutorials/getting-started.md): a
  complete, compiling, end-to-end walkthrough from DSL declaration through
  direct dispatch, a supervised agent process, HTTP serving with
  `A2A.Plug`/`A2A.Client`, and role-based LLM provider resolution.
- **How-to guides**:
  - [Authenticate inbound A2A requests](docs/how-to/authenticate-agent-requests.md)
    — wire `A2A.Plug.Auth` in front of `A2A.Plug` so a Bearer credential
    becomes `context.actor`/`context.tenant` inside your Ash actions.
  - [Observe dispatch with OCEL](docs/how-to/observe-dispatch-with-ocel.md)
    — forward every `AshA2A.Dispatcher` skill dispatch as an OCEL v2 event
    to an external process-mining ingest endpoint.
  - [Use role-based LLM resolution](docs/how-to/use-role-based-llm-resolution.md)
    — add an LLM-backed action that declares an abstract role instead of
    hardcoding a provider/model string.
- **Reference** — [Reference index](docs/reference/index.md): module and
  DSL lookup.
- **Explanation** — [Architecture](docs/explanation/architecture.md): how
  the capability index, verifier, dispatcher, and agent process fit together
  and why they're designed that way.

## Installer

`mix ash_a2a.install` (an Igniter task) wires the extension into a project;
see `lib/mix/tasks/ash_a2a.install.ex`.

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm).
