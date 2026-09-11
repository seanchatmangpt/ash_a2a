defmodule AshA2A.Test.PlugFixture.Greeter do
  @moduledoc """
  Real fixture resource for `test/ash_a2a_plug_agent_card_test.exs` -- a
  genuine `Ash.Resource` with `extensions: [AshA2A]` and one real `a2a do
  skill ... end` declaration, distinct from `test/support/fixture.ex`'s
  `AshA2A.Test.Fixture.Echo` so this file's real `A2A.Plug`-fronted agent
  process can be started/stopped independently without colliding with other
  concurrently-running test files' fixtures (assignment #3, ash_a2a A2A.Plug
  agent-card serving hardening task).
  """

  use Ash.Resource,
    domain: AshA2A.Test.PlugFixture.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:greeting, :string, public?: true)
  end

  actions do
    defaults([:read])
  end

  a2a do
    skill(:greet, :read)
  end
end

defmodule AshA2A.Test.PlugFixture.Domain do
  @moduledoc """
  Real fixture domain pairing `AshA2A.Test.PlugFixture.Greeter` above, so
  `AshA2A.Info.agent_card/2` has a real, verified capability index to build
  from -- the same real card the `AshA2A.Agent`-generated GenServer below
  advertises through a real `A2A.Plug` HTTP pipeline.
  """

  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2A.Test.PlugFixture.Greeter)
  end
end

defmodule AshA2A.Test.PlugFixture.GreeterAgent do
  @moduledoc """
  Real `A2A.Agent` GenServer (via `use AshA2A.Agent`) over the
  `AshA2A.Test.PlugFixture.Greeter` resource above, started directly (not
  under `AshA2A.Test.AgentSupervisorCase`'s shared supervisor) by
  `test/ash_a2a_plug_agent_card_test.exs` so a real `A2A.Plug` `:agent`
  option can reference its real registered process name and receive a real
  `GenServer.call(agent, :get_agent_card)` -- the exact call
  `A2A.Plug`'s `serve_agent_card/2` (`~/xaas/deps/a2a/lib/a2a/plug.ex:172-184`)
  makes on every real HTTP GET to the agent-card path.
  """

  use AshA2A.Agent, resource_or_domain: AshA2A.Test.PlugFixture.Greeter, name: "greeter_agent"
end
