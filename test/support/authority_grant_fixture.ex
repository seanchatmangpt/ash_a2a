defmodule AshA2A.Test.Fixture.ActuationCounter do
  @moduledoc """
  Real, separately-supervised counter process (a plain `Agent`) used as the
  "did this consequential action ACTUALLY run" evidence for
  `test/ash_a2a_authority_capability_grant_test.exs`.

  Deliberately a real process rather than a `send(self(), ...)` marker: the
  real Ash action body runs inside the `A2A.Agent` GenServer's own process,
  not the test process, so a `self()`-directed message can never reach the
  test and a `refute_receive` on one would pass vacuously whether or not the
  action ran. A named counter process is observed by the test with a real
  state-based read (`count/1`), which is the actual Chicago-style assertion:
  the number of real actuations, not whether some function was called.
  """

  use Agent

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> 0 end, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec bump(atom()) :: :ok
  def bump(name \\ __MODULE__) do
    case Process.whereis(name) do
      nil -> :ok
      _pid -> Agent.update(name, &(&1 + 1))
    end
  end

  @spec count(atom()) :: non_neg_integer()
  def count(name \\ __MODULE__), do: Agent.get(name, & &1)
end

defmodule AshA2A.Test.Fixture.GrantProbe do
  @moduledoc """
  Real fixture resource whose skills span all three real consequence classes
  the authority-grant decision distinguishes:

    * `:touch` -- `consequence: :external_do`, the escalation-relevant class.
      Its real body bumps `AshA2A.Test.Fixture.ActuationCounter`, so "was this
      actuated" is answered by a real counter read, never by an interaction
      assertion.
    * `:mutate` -- `consequence: :change`, the other escalation-relevant class,
      likewise counted.
    * `:peek` -- `consequence: :observe`, which `AshA2A.CommandBus.admit/2`
      admits unconditionally and which therefore MUST remain reachable with no
      capability grant at all.
  """

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.GrantProbeDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])

    action :touch, :map do
      argument(:note, :string, allow_nil?: true)

      run(fn input, _context ->
        AshA2A.Test.Fixture.ActuationCounter.bump()
        {:ok, %{actuated: true, note: input.arguments[:note]}}
      end)
    end

    action :mutate, :map do
      argument(:note, :string, allow_nil?: true)

      run(fn input, _context ->
        AshA2A.Test.Fixture.ActuationCounter.bump()
        {:ok, %{mutated: true, note: input.arguments[:note]}}
      end)
    end

    action :peek, :map do
      run(fn _input, _context -> {:ok, %{peeked: true}} end)
    end
  end

  a2a do
    skill(:touch, :touch, consequence: :external_do)
    skill(:mutate, :mutate, consequence: :change)
    skill(:peek, :peek, consequence: :observe)
  end
end

defmodule AshA2A.Test.Fixture.GrantProbeDomain do
  @moduledoc "Real fixture domain for `AshA2A.Test.Fixture.GrantProbe` above."

  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2A.Test.Fixture.GrantProbe)
  end
end

defmodule AshA2A.Test.Fixture.GrantProbeAgent do
  @moduledoc "Real `A2A.Agent` GenServer over `AshA2A.Test.Fixture.GrantProbe`."

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.GrantProbe,
    name: "grant_probe_agent"
end
