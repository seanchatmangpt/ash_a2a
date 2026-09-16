defmodule AshA2A.Test.ActuatorCounter do
  @moduledoc """
  A REAL counting actuator for the SA2A authority court. Not a mock: a real
  `GenServer` holding real state, incremented by a real Ash action running
  through the real `AshA2A.Dispatcher`. Tests assert on its real count
  (state), never on "was it called" (interaction).

  `AshA2A.Test.Fixture.AuthorityProbe.actuate/0` is the only thing that
  increments it, and that action is declared `consequence: :external_do`, so
  reaching it at all means the `AshA2A.CommandBus` authority gate was
  crossed. A count of 0 after a full ADMITTED -> PLANNABLE -> SELECTED ->
  CONSTRUCTED -> REFUSED_AUTHORITY run is therefore a real observation that
  no side effect occurred, not an inference from the refusal tuple.
  """
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, 0, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl GenServer
  def init(count), do: {:ok, count}

  @doc "Increments and returns the new count. Called only from past the authority gate."
  @spec increment(atom()) :: non_neg_integer()
  def increment(name \\ __MODULE__), do: GenServer.call(name, :increment)

  @doc "Reads the real current count."
  @spec count(atom()) :: non_neg_integer()
  def count(name \\ __MODULE__), do: GenServer.call(name, :count)

  @impl GenServer
  def handle_call(:increment, _from, count), do: {:reply, count + 1, count + 1}
  def handle_call(:count, _from, count), do: {:reply, count, count}
end

defmodule AshA2A.Test.Fixture.AuthorityProbe do
  @moduledoc """
  Real `Ash.Resource` whose `:actuate` skill is classified
  `consequence: :external_do` and whose run function performs a REAL,
  externally-observable side effect (incrementing
  `AshA2A.Test.ActuatorCounter`).

  Paired `:observe` skill `:peek` reads the counter without touching it, so a
  test can prove the counter/dispatch wiring genuinely works end to end
  before asserting that the authority-refused path leaves it at zero.
  """

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.AuthorityProbeDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])

    action :actuate, :integer do
      run(fn _input, _context -> {:ok, AshA2A.Test.ActuatorCounter.increment()} end)
    end

    action :peek, :integer do
      run(fn _input, _context -> {:ok, AshA2A.Test.ActuatorCounter.count()} end)
    end
  end

  a2a do
    skill(:actuate, :actuate, consequence: :external_do)
    skill(:peek, :peek, consequence: :observe)
  end
end

defmodule AshA2A.Test.Fixture.AuthorityProbeDomain do
  @moduledoc "Real fixture domain for `AshA2A.Test.Fixture.AuthorityProbe`."

  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2A.Test.Fixture.AuthorityProbe)
  end
end
