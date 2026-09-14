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

defmodule AshA2A.Test.Fixture.Locked do
  @moduledoc """
  Real fixture resource with `authorizers: [Ash.Policy.Authorizer]` and a
  policy that always forbids (`policy always() do forbid_unless(always())
  end`), paired with `AshA2A.Test.Fixture.LockedDomain`'s `authorization do
  authorize(:always) end` -- so dispatching it with no actor makes the real,
  bundled `Ash.Policy.Authorizer` raise a genuine, unmocked
  `Ash.Error.Forbidden.Policy` (`class: :forbidden`). Used by
  `test/ash_a2a_test.exs` to exercise `AshA2A.Dispatcher.to_reply/1`'s
  `{:error, %{class: :forbidden}}` branch through a real Ash authorization
  denial, not a hand-built term -- `Ash.Policy.Authorizer` ships in core
  `ash` (no separate `ash_policy_authorizer` dependency needed).
  """

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.LockedDomain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  policies do
    policy always() do
      forbid_unless(always())
    end
  end

  actions do
    defaults([:read])
  end

  a2a do
    skill(:list, :read)
  end
end

defmodule AshA2A.Test.Fixture.LockedDomain do
  @moduledoc """
  Real fixture domain for `AshA2A.Test.Fixture.Locked` above --
  `authorization do authorize(:always) end` turns authorization on for every
  dispatch against it (`Ash.Domain.Info.authorize/1` -> `:always`), which is
  what actually engages the resource's always-forbid policy.
  """

  use Ash.Domain, extensions: [AshA2A]

  authorization do
    authorize(:always)
  end

  resources do
    resource(AshA2A.Test.Fixture.Locked)
  end
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

defmodule AshA2A.Test.Fixture.Item do
  @moduledoc """
  Real fixture resource covering the `:create`, `:update`, `:destroy`, and
  generic `:action`-shaped skills `AshA2A.Dispatcher` handles
  (`lib/ash_a2a/dispatcher.ex` `run_create/4`, `run_update/4`, `run_destroy/4`,
  `run_generic/4`) -- previously only `:read`-shaped skills existed as
  fixtures (`Echo`, `Widget`), so those four dispatch branches, and
  `to_reply/1`'s real `Ash.Error.Invalid` -> `:input_required` mapping for a
  missing required create argument, were untested against a real compiled
  resource. A genuine `Ash.Resource` with `extensions: [AshA2A]`, real
  `:create`/`:update`/`:destroy` default actions restricted to a required
  `:label` attribute (so a caller-omitted `label` on create produces a real
  `Ash.Error.Invalid`), and one real generic `:action` (`:ping`, returning a
  plain string).
  """

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.ItemDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:label, :string, public?: true, allow_nil?: false)
  end

  actions do
    defaults([:read, :destroy, create: [:label], update: [:label]])

    action :ping, :string do
      run(fn _input, _context -> {:ok, "pong"} end)
    end
  end

  a2a do
    skill(:create_item, :create)
    skill(:update_item, :update)
    skill(:destroy_item, :destroy)
    skill(:ping, :ping, consequence: :observe)
  end
end

defmodule AshA2A.Test.Fixture.ItemDomain do
  @moduledoc """
  Real fixture domain for `AshA2A.Test.Fixture.Item` above, mirroring
  `AshA2A.Test.Fixture.Domain`'s shape but kept separate so the
  create/update/destroy/action fixture is its own genuine Ash domain.
  """

  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2A.Test.Fixture.Item)
  end
end

defmodule AshA2A.Test.Fixture.TenantedItem do
  @moduledoc """
  Real multitenant fixture resource for the `TenantRequired`-carve-out
  regression coverage in `test/ash_a2a_dispatcher_tenant_test.exs`. A genuine
  `Ash.Resource` with `multitenancy do strategy :attribute ...  end` and
  `extensions: [AshA2A]`, real `:create`/`:update`/`:destroy` default
  actions. Dispatching `:create`/`:update`/`:destroy` skills against this
  resource with no tenant in context makes Ash's own multitenancy
  enforcement (`Ash.Actions.Helpers.validate_changeset_multitenancy/1`) raise
  a real, unmocked `Ash.Error.Changes.InvalidChanges` (`class: :invalid`)
  wrapped inside a top-level `Ash.Error.Invalid{errors: [...]}` -- exactly
  the shape `deps/ash/lib/ash/actions/create.ex`/`update.ex`/`destroy.ex`
  actually produce, distinct from the `Ash.Error.Invalid.TenantRequired`
  struct only `:read` raises.
  """

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.TenantedItemDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  multitenancy do
    strategy(:attribute)
    attribute(:tenant)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:tenant, :string, public?: true, allow_nil?: false)
    attribute(:label, :string, public?: true, allow_nil?: false)
  end

  actions do
    defaults([:read, :destroy, create: [:label], update: [:label]])
  end

  a2a do
    skill(:create_tenanted_item, :create)
    skill(:update_tenanted_item, :update)
    skill(:destroy_tenanted_item, :destroy)
  end
end

defmodule AshA2A.Test.Fixture.EchoWithArgument do
  @moduledoc """
  Real fixture resource proving the `:skill` entity's `entities: [arguments:
  [@argument]]` (`lib/ash_a2a/dsl.ex`) actually accepts a nested `do...end`
  block: `skill :echo, :read do argument :query, :string end` below is a
  genuine `Spark.Dsl.Entity` nested-entity declaration, compiled for real (no
  mocked DSL/parser), not a hand-built `%AshA2A.Skill{}` struct literal.
  """

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.EchoWithArgumentDomain,
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
    skill :echo, :read do
      argument(:query, :string)
    end
  end
end

defmodule AshA2A.Test.Fixture.EchoWithArgumentDomain do
  @moduledoc """
  Real fixture domain for `AshA2A.Test.Fixture.EchoWithArgument` above.
  """

  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2A.Test.Fixture.EchoWithArgument)
  end
end

defmodule AshA2A.Test.Fixture.TenantedItemDomain do
  @moduledoc """
  Real fixture domain for `AshA2A.Test.Fixture.TenantedItem` above.
  """

  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2A.Test.Fixture.TenantedItem)
  end
end
