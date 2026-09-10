defmodule AshA2A.Test.Fixture.Echo do
  @moduledoc """
  Real fixture resource for `test/ash_a2a_test.exs` -- a genuine Ash.Resource
  with `extensions: [AshA2A]` and one real `a2a do skill ... end` declaration
  (ash_a2a PRD/ARD §3.1). Not compiled inline in the test module: a real
  support file, per this workspace's Chicago-style testing discipline (real
  collaborators, state-based assertions, no Mock/mox/patch).
  """

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.Domain,
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

defmodule AshA2A.Test.Fixture.Domain do
  @moduledoc """
  Real fixture domain for `test/ash_a2a_test.exs`, using `extensions:
  [AshA2A]` at the domain level -- the dual-level fixture the ash_a2a
  PRD/ARD §3.1 requires (resource-level and domain-level both accept the same
  `AshA2A` extension). Declares no domain-level skills of its own; the
  resource above already declares one, and `AshA2A.Transformers
  .BuildCapabilityIndex` still compiles a (here, empty) capability index for
  the domain, proving the extension attaches cleanly at both levels.
  """

  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2A.Test.Fixture.Echo)
  end
end

defmodule AshA2A.Test.Fixture.EchoAgent do
  @moduledoc """
  Real `A2A.Agent` GenServer built with `use AshA2A.Agent` over the fixture
  `Echo` resource above, for `test/ash_a2a_test.exs` to start under a real
  `A2A.AgentSupervisor` and send a real `A2A.Message` to -- exercising
  `AshA2A.Dispatcher.dispatch/3` through an actual supervised process
  instead of only as a bare synchronous function call.
  """

  use AshA2A.Agent, resource_or_domain: AshA2A.Test.Fixture.Echo, name: "echo_agent"
end

defmodule AshA2A.Test.Fixture.NoA2A do
  @moduledoc """
  Real fixture resource for doctests (`AshA2A.Info` task #19): a genuine
  `Ash.Resource`, compiled as a real Spark DSL module, but deliberately
  *without* `extensions: [AshA2A]` -- so `AshA2A.Info.capability_index_result/1`
  and friends have a real "not compiled" case to exercise against a module
  that is a valid `Spark.Dsl.Extension` target (unlike a non-Spark module such
  as `String`, which `Spark.Dsl.Extension.get_persisted/3` raises on rather
  than returning `nil`/`:error` for).
  """

  use Ash.Resource,
    domain: nil,
    data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])
  end
end

defmodule AshA2A.Test.Fixture.Widget do
  @moduledoc """
  Second, distinct real fixture resource (ash_a2a task #22 -- multi-agent
  `A2A.Registry` collision test in `test/ash_a2a_registry_test.exs`). A
  genuine `Ash.Resource` with its own `extensions: [AshA2A]` and its own real
  `a2a do skill ... end` declaration, deliberately separate from
  `AshA2A.Test.Fixture.Echo` above so a real second `AshA2A.Agent` module can
  be started under the *same* `A2A.AgentSupervisor`/`A2A.Registry` as
  `EchoAgent` and both asserted to resolve to distinct, non-colliding real
  registry identities -- not two aliases of the same compiled fixture.
  """

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.WidgetDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:label, :string, public?: true)
  end

  actions do
    defaults([:read])
  end

  a2a do
    skill(:inspect, :read)
  end
end

defmodule AshA2A.Test.Fixture.WidgetDomain do
  @moduledoc """
  Real fixture domain for `AshA2A.Test.Fixture.Widget` above, mirroring
  `AshA2A.Test.Fixture.Domain`'s shape but kept as its own separate module so
  the two fixture resources used by the multi-agent registry collision test
  (`test/ash_a2a_registry_test.exs`) are genuinely independent Ash domains,
  not two resources sharing one domain.
  """

  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2A.Test.Fixture.Widget)
  end
end

defmodule AshA2A.Test.Fixture.WidgetAgent do
  @moduledoc """
  Real `A2A.Agent` GenServer built with `use AshA2A.Agent` over the fixture
  `Widget` resource above, for `test/ash_a2a_registry_test.exs` to start
  alongside `AshA2A.Test.Fixture.EchoAgent` under one real
  `A2A.AgentSupervisor` -- exercising `A2A.Registry`'s real per-module ETS
  keying with two genuinely distinct agent modules/cards instead of just one.
  """

  use AshA2A.Agent, resource_or_domain: AshA2A.Test.Fixture.Widget, name: "widget_agent"
end
