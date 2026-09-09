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
