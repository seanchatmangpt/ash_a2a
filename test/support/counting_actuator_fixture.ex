defmodule AshA2A.Test.Fixture.ActuationCounter do
  @moduledoc """
  A real, observable side-effect counter for RFC-SA2A-001 S32/S55 tests.

  This is not a mock and not a spy: it is an ordinary supervised `Agent`
  holding a real integer per effect key, and the assertions read that real
  integer's real value. Nothing here records "was this called" -- the count is
  the resulting state, which is exactly what makes "replay did not re-actuate"
  a state-based claim rather than an interaction-based one.
  """
  use Agent

  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{} end, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Performs the real effect: increments the counter for `key`, returns the new count."
  def bump(key, name \\ __MODULE__) do
    Agent.get_and_update(name, fn state ->
      count = Map.get(state, key, 0) + 1
      {count, Map.put(state, key, count)}
    end)
  end

  @doc "The real number of times the effect actually ran for `key`."
  def count(key, name \\ __MODULE__), do: Agent.get(name, &Map.get(&1, key, 0))
end

defmodule AshA2A.Test.Fixture.CountingActuator do
  @moduledoc """
  Real `Ash.Resource` whose `:actuate` skill is classified `:external_do` and
  performs a genuinely observable side effect (incrementing
  `AshA2A.Test.Fixture.ActuationCounter`).

  Existing fixtures (`Echo`, `Item`) cannot prove "replay did not re-actuate":
  `Echo.read` has no effect to repeat, and `Item.create` writes to an ETS data
  layer whose row count is a weaker signal than a monotonic counter (a second
  create with the same attributes is hard to distinguish from the first). A
  counter increments once per real crossing of the consequence boundary, full
  stop -- which is the precise observable S32 and S55 need.
  """

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.CountingActuatorDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    action :actuate, :integer do
      argument(:effect_key, :string, allow_nil?: false)

      run(fn input, _context ->
        {:ok, AshA2A.Test.Fixture.ActuationCounter.bump(input.arguments.effect_key)}
      end)
    end
  end

  a2a do
    skill(:actuate, :actuate, consequence: :external_do)
  end
end

defmodule AshA2A.Test.Fixture.CountingActuatorDomain do
  @moduledoc "Real fixture domain for `AshA2A.Test.Fixture.CountingActuator`."

  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2A.Test.Fixture.CountingActuator)
  end
end
