defmodule AshA2A.Chicago.Fixtures.Postcondition do
  @moduledoc """
  Real fixtures for the Gate 8 independent-postcondition court
  (`AshA2A.Chicago.Courts.Postcondition`, RFC-SA2A-002 §39, §73).

  `Ledger` is a genuine ETS-backed `Ash.Resource` exposed through `AshA2A`
  with three consequence-bearing actuators that differ only in how honestly
  they report:

    * `:honest_write` -- Ash's own `:create`; the report is the stored row
    * `:lying_write` -- reports `%{key, value}` success but writes nothing
    * `:divergent_write` -- writes `value <> ":diverged"` (Y) while reporting
      `value` (X)

  and three postcondition verifiers:

    * `LedgerVerifier` -- independent: instantiates its own filtered `Ash.Query`
      and reads the ETS data layer; never looks at the actuator's report
    * `ReportReadingVerifier` -- NOT independent: reads only the actuator's
      return object
    * `AlwaysRefusingVerifier` -- refuses every claim (vacuity control, §100)

  `stored_values/1` is the court's own post-state reader: a full unfiltered
  `Ash.read!/1` scan, a different query shape from `LedgerVerifier`'s, so the
  court does not collude with the verifier it qualifies.
  """

  alias AshA2A.Chicago.Fixtures.Postcondition.Ledger

  @doc "Every stored value for `key`, read by a full scan (the court's reader)."
  @spec stored_values(String.t()) :: [String.t()]
  def stored_values(key) do
    Ledger
    |> Ash.read!()
    |> Enum.filter(&(&1.key == key))
    |> Enum.map(& &1.value)
    |> Enum.sort()
  end

  @doc "Capability id of a `Ledger` action."
  @spec capability(atom()) :: String.t()
  def capability(action), do: inspect(Ledger) <> "." <> Atom.to_string(action)
end

defmodule AshA2A.Chicago.Fixtures.Postcondition.Ledger do
  @moduledoc "ETS ledger with honest, lying and divergent actuators. See the parent moduledoc."

  use Ash.Resource,
    domain: AshA2A.Chicago.Fixtures.Postcondition.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:key, :string, public?: true, allow_nil?: false)
    attribute(:value, :string, public?: true, allow_nil?: false)
  end

  actions do
    defaults([:read, create: [:key, :value]])

    create :honest_write do
      accept([:key, :value])
    end

    action :lying_write, :map do
      argument(:key, :string, allow_nil?: false)
      argument(:value, :string, allow_nil?: false)

      run(fn input, _context ->
        {:ok, %{key: input.arguments.key, value: input.arguments.value}}
      end)
    end

    action :divergent_write, :map do
      argument(:key, :string, allow_nil?: false)
      argument(:value, :string, allow_nil?: false)

      run(fn input, _context ->
        %{key: key, value: reported} = input.arguments

        __MODULE__
        |> Ash.Changeset.for_create(:create, %{key: key, value: reported <> ":diverged"})
        |> Ash.create()
        |> case do
          {:ok, _written} -> {:ok, %{key: key, value: reported}}
          {:error, error} -> {:error, error}
        end
      end)
    end
  end

  a2a do
    skill(:honest_write, :honest_write)
    skill(:lying_write, :lying_write, consequence: :change)
    skill(:divergent_write, :divergent_write, consequence: :change)
  end
end

defmodule AshA2A.Chicago.Fixtures.Postcondition.Domain do
  @moduledoc "Fixture domain for `Ledger` (compiled in every env; not a host-app domain)."

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.Chicago.Fixtures.Postcondition.Ledger)
  end
end

defmodule AshA2A.Chicago.Fixtures.Postcondition.LedgerVerifier do
  @moduledoc """
  Independent verifier: expectation `%{key, value}` holds iff an independently
  instantiated, key-filtered `Ash.Query` over the ledger returns exactly
  `[value]`. The actuator's report is never read.
  """

  @behaviour AshA2A.Postcondition

  require Ash.Query

  alias AshA2A.Chicago.Fixtures.Postcondition.Ledger

  @impl true
  def verify(%{key: key, value: expected}, _probe) do
    case Ledger |> Ash.Query.filter(key == ^key) |> Ash.read() do
      {:ok, rows} ->
        observed = rows |> Enum.map(& &1.value) |> Enum.sort()
        evidence = %{"expected" => expected, "observed" => observed}
        if observed == [expected], do: {:verified, evidence}, else: {:contradicted, evidence}

      {:error, error} ->
        {:unverified, "ledger read failed: " <> Exception.message(error)}
    end
  end
end

defmodule AshA2A.Chicago.Fixtures.Postcondition.ReportReadingVerifier do
  @moduledoc """
  Non-independent verifier: "verifies" by reading only the actuator's return
  object. It can never contradict an actuator that lies consistently (§73).
  """

  @behaviour AshA2A.Postcondition

  @impl true
  def verify(%{value: expected}, %AshA2A.Postcondition.Probe{actuator_report: report}) do
    reported = reported_value(report)
    evidence = %{"expected" => expected, "reported" => inspect(reported)}
    if reported == expected, do: {:verified, evidence}, else: {:contradicted, evidence}
  end

  defp reported_value({:reply, parts}) when is_list(parts) do
    Enum.find_value(parts, fn
      %A2A.Part.Data{data: data} when is_map(data) -> data[:value] || data["value"]
      _ -> nil
    end)
  end

  defp reported_value(_report), do: nil
end

defmodule AshA2A.Chicago.Fixtures.Postcondition.AlwaysRefusingVerifier do
  @moduledoc "Refuses every success claim, true or false (negative vacuity control, §100)."

  @behaviour AshA2A.Postcondition

  @impl true
  def verify(_expect, _probe), do: {:contradicted, %{"refused" => "always"}}
end
