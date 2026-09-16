defmodule AshA2A.Chicago.Fixtures.Brce.Ledger do
  @moduledoc """
  Real Ash resource the `CHI-BRCE` court (RFC-SA2A-002 §38, §68, §69) attacks.

  Every consequence class the sole-DO boundary must discriminate is present
  as a real, public Ash action exposed through the real `AshA2A` extension:

    * `:record` (`:create`, default consequence `:change`) -- writes a real
      ETS row; the forbidden consequence of every bypass attack.
    * `:transmit` (generic action, declared `:external_do`) -- writes a real
      row into `AshA2A.Chicago.Fixtures.Brce.ExternalEffect`, a separate
      resource standing in for the external system. Nothing is faked: the
      effect is a real persisted row an independent reader can count.
    * `:entries` (`:read`, `:observe`) -- the lawful non-consequence path
      used by the dispatcher-discrimination positive control.

  Post-state is always read back through `Ash.read!/1` -- an independent
  reader, never the actuator's return value (§39, §73).
  """

  use Ash.Resource,
    domain: AshA2A.Chicago.Fixtures.Brce.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:label, :string, public?: true, allow_nil?: false)
  end

  actions do
    defaults(create: [:label])

    read :entries do
      primary?(true)
    end

    action :transmit, :string do
      argument(:label, :string, allow_nil?: false)

      run(fn input, _context ->
        AshA2A.Chicago.Fixtures.Brce.transmit_effect(input.arguments.label)
      end)
    end
  end

  a2a do
    skill(:record, :create)
    skill(:transmit, :transmit, consequence: :external_do)
    skill(:entries, :entries, consequence: :observe)
  end
end

defmodule AshA2A.Chicago.Fixtures.Brce.ExternalEffect do
  @moduledoc """
  The "external system" side of `Ledger.transmit`: one real ETS row per real
  external actuation. Deliberately NOT an `AshA2A` resource -- it is the
  environment the actuator changes, not a capability.
  """

  use Ash.Resource,
    domain: AshA2A.Chicago.Fixtures.Brce.Domain,
    data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key(:id)
    attribute(:label, :string, public?: true, allow_nil?: false)
  end

  actions do
    defaults([:read, create: [:label]])
  end
end

defmodule AshA2A.Chicago.Fixtures.Brce.Planned do
  @moduledoc """
  Real planning-surface resource for the planner / semantic-request bypass
  falsifiers: `semantic_requests(true)` plus two HDDL operators whose actions
  are genuinely consequence-bearing.

    * `:advance` (`:change`) -- writes a real `Ledger` row labelled
      `"advance:<from>-><to>"` when actuated.
    * `:unlock` (`:external_do`) -- writes a real `ExternalEffect` row
      labelled `"unlock:<who>"` when actuated.

  A planner or semantic path that produced a plan naming these capabilities
  and then actuated it would leave those rows behind; the court reads them
  back independently.
  """

  use Ash.Resource,
    domain: AshA2A.Chicago.Fixtures.Brce.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])

    action :advance, :string do
      argument(:from, :string, allow_nil?: false)
      argument(:to, :string, allow_nil?: false)

      run(fn input, _context ->
        AshA2A.Chicago.Fixtures.Brce.record_label(
          "advance:#{input.arguments.from}->#{input.arguments.to}"
        )
      end)
    end

    action :unlock, :string do
      argument(:who, :string, allow_nil?: false)

      run(fn input, _context ->
        AshA2A.Chicago.Fixtures.Brce.transmit_effect("unlock:#{input.arguments.who}")
      end)
    end
  end

  a2a do
    semantic_requests(true)

    skill :advance, :advance do
      consequence(:change)

      hddl_operator do
        parameters([:from, :to])
        preconditions([{:current_phase, [:from]}])
        add_effects([{:current_phase, [:to]}])
        delete_effects([{:current_phase, [:from]}])
      end
    end

    skill :unlock, :unlock do
      consequence(:external_do)

      hddl_operator do
        parameters([:who])
        preconditions([{:current_phase, [:who]}])
        add_effects([{:has_key, [:who]}])
      end
    end

    skill(:planned_entries, :read, consequence: :observe)
  end
end

defmodule AshA2A.Chicago.Fixtures.Brce.Domain do
  @moduledoc """
  Real fixture domain for the `CHI-BRCE` court. Compiled in every Mix env
  (`lib/`), so `validate_config_inclusion?: false` keeps
  `mix compile --warnings-as-errors` clean without registering a court
  fixture as a host application domain.
  """

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshA2A.Chicago.Fixtures.Brce.Ledger)
    resource(AshA2A.Chicago.Fixtures.Brce.ExternalEffect)
    resource(AshA2A.Chicago.Fixtures.Brce.Planned)
  end
end

defmodule AshA2A.Chicago.Fixtures.Brce.LedgerAgent do
  @moduledoc """
  The generated `use AshA2A.Agent` projection over `Ledger` -- the A2A task
  handler and generated-artifact surfaces the court attacks. Started as a
  real `A2A.Agent` GenServer per stimulus; never registered globally.
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Chicago.Fixtures.Brce.Ledger,
    name: "chicago_brce_ledger_agent"
end

defmodule AshA2A.Chicago.Fixtures.Brce.PlannedAgent do
  @moduledoc "The generated `use AshA2A.Agent` projection over `Planned` (semantic requests)."

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Chicago.Fixtures.Brce.Planned,
    name: "chicago_brce_planned_agent"
end

defmodule AshA2A.Chicago.Fixtures.Brce do
  @moduledoc """
  Shared real consequence helpers and independent post-state readers for the
  `CHI-BRCE` court fixtures.
  """

  alias AshA2A.Chicago.Fixtures.Brce.{ExternalEffect, Ledger}

  @doc false
  @spec record_label(String.t()) :: {:ok, String.t()} | {:error, term()}
  def record_label(label) do
    Ledger
    |> Ash.Changeset.for_create(:create, %{label: label})
    |> Ash.create()
    |> case do
      {:ok, _row} -> {:ok, label}
      {:error, error} -> {:error, error}
    end
  end

  @doc false
  @spec transmit_effect(String.t()) :: {:ok, String.t()} | {:error, term()}
  def transmit_effect(label) do
    ExternalEffect
    |> Ash.Changeset.for_create(:create, %{label: label})
    |> Ash.create()
    |> case do
      {:ok, _row} -> {:ok, label}
      {:error, error} -> {:error, error}
    end
  end

  @doc "Independent reader: every `Ledger` label currently persisted."
  @spec ledger_labels() :: [String.t()]
  def ledger_labels, do: Ledger |> Ash.read!() |> Enum.map(& &1.label)

  @doc "Independent reader: every external-effect label currently persisted."
  @spec effect_labels() :: [String.t()]
  def effect_labels, do: ExternalEffect |> Ash.read!() |> Enum.map(& &1.label)

  @doc "Number of persisted rows (ledger + external) carrying `label`."
  @spec consequence_count(String.t()) :: non_neg_integer()
  def consequence_count(label) do
    Enum.count(ledger_labels(), &(&1 == label)) + Enum.count(effect_labels(), &(&1 == label))
  end
end
