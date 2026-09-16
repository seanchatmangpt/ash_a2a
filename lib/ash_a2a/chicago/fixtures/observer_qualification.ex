defmodule AshA2A.Chicago.Fixtures.ObserverQualification do
  @moduledoc """
  Fixtures for `AshA2A.Chicago.Courts.ObserverQualification` (RFC-SA2A-002
  §138, §139, §108).

  Everything here is real: real `:telemetry` emission, real mappings applied
  by a real `AshA2A.Chicago.Observer`, a real Ash ETS resource driven through
  the real `AshA2A.CommandBus`, and real non-discoverable inner courts run by
  the real `AshA2A.Chicago.Runner`. Fault injection changes the environment
  around a real component (a killed or suspended observer process, a flipped
  byte in a real file) -- it never replaces the component under qualification
  (§10).

  Fixture telemetry is emitted through `emit/3` with a non-literal event name
  and lives under `[:ash_a2a, :chicago, :fixtures | _]`, which SUT event
  discovery (`AshA2A.Chicago.Ocel.SutEvents`) excludes, so fixture traffic
  never floods a real run's observer.
  """

  alias AshA2A.Chicago.Ocel.Mapping

  @prefix [:ash_a2a, :chicago, :fixtures, :observer_qualification]

  @doc "Fixture event name `[:ash_a2a, :chicago, :fixtures, :observer_qualification, name]`."
  @spec event(atom()) :: [atom()]
  def event(name) when is_atom(name), do: @prefix ++ [name]

  @doc "Emits a fixture telemetry event (non-literal name: invisible to static discovery)."
  @spec emit(atom() | [atom()], map(), map()) :: :ok
  def emit(name, measurements, metadata) when is_atom(name),
    do: emit(event(name), measurements, metadata)

  def emit(event, measurements, metadata) when is_list(event),
    do: :telemetry.execute(event, measurements, metadata)

  @doc "Emits one probe event."
  @spec probe(map()) :: :ok
  def probe(metadata), do: emit(:probe, %{count: 1}, metadata)

  @doc "`fixture.probe`: one probe object per event, id from `:probe_id`."
  @spec probe_mapping() :: Mapping.t()
  def probe_mapping do
    Mapping.new!(
      event: event(:probe),
      activity: "fixture.probe",
      source: __MODULE__,
      objects: fn _m, meta -> [{"probe", meta[:probe_id], "probe"}] end,
      attributes: fn _m, meta -> Map.take(meta, [:i, :emitter, :label]) end
    )
  end

  @doc """
  `fixture.refs` / `fixture.typed`: object refs are taken verbatim from the
  event's `:refs` metadata, so a court can present the observer with exactly
  the (possibly malformed) relationship identities under attack.
  """
  @spec refs_mapping(:refs | :typed) :: Mapping.t()
  def refs_mapping(name \\ :refs) when name in [:refs, :typed] do
    Mapping.new!(
      event: event(name),
      activity: "fixture.#{name}",
      source: __MODULE__,
      objects: fn _m, meta -> Map.get(meta, :refs, []) end,
      attributes: fn _m, meta -> Map.take(meta, [:label]) end
    )
  end

  @doc """
  `fixture.twin`, mapped by two admitted mappings at once: one telemetry
  event must yield two records with distinct identities.
  """
  @spec twin_mappings() :: [Mapping.t()]
  def twin_mappings do
    for side <- ["left", "right"] do
      Mapping.new!(
        event: event(:twin),
        activity: "fixture.twin.#{side}",
        source: __MODULE__,
        objects: fn _m, meta -> [{"twin", meta[:twin_id], side}] end
      )
    end
  end

  @doc """
  `fixture.gated`: the mapping blocks inside the emitting process until the
  gate owner releases it -- after the observer's handler has already taken
  the event's sequence number. Models a descheduled emitter whose record is
  delivered out of order.
  """
  @spec gated_mapping() :: Mapping.t()
  def gated_mapping do
    Mapping.new!(
      event: event(:gated),
      activity: "fixture.gated",
      source: __MODULE__,
      objects: fn _m, meta ->
        send(meta.gate_owner, {:gated_waiting, self(), meta.gate_ref})
        ref = meta.gate_ref

        receive do
          {:release, ^ref} -> [{"probe", meta[:probe_id], "probe"}]
        after
          30_000 -> [{"probe", meta[:probe_id], "probe"}]
        end
      end,
      attributes: fn _m, meta -> Map.take(meta, [:label]) end
    )
  end
end

defmodule AshA2A.Chicago.Fixtures.ObserverQualification.Ledger do
  @moduledoc """
  Real Ash ETS resource with one `:change` skill, driven through the real
  `AshA2A.CommandBus` while an observer is down (§108: an observer outage
  must never produce an execution). Rows are read back with `Ash.read!/1` --
  an independent reader, not the actuator's reply.
  """

  use Ash.Resource,
    domain: AshA2A.Chicago.Fixtures.ObserverQualification.LedgerDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:label, :string, public?: true, allow_nil?: false)
  end

  actions do
    defaults([:read, create: [:label]])
  end

  a2a do
    skill(:create_entry, :create)
  end
end

defmodule AshA2A.Chicago.Fixtures.ObserverQualification.LedgerDomain do
  @moduledoc "Domain for the observer-qualification `Ledger` fixture."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshA2A.Chicago.Fixtures.ObserverQualification.Ledger)
  end
end

defmodule AshA2A.Chicago.Fixtures.ObserverQualification.InnerCourt do
  @moduledoc """
  Shared shape of the non-discoverable inner courts the observer court runs
  through the real `AshA2A.Chicago.Runner`: one positive-control falsifier
  whose stimulus emits real probe events. `use` with `:id` and a
  `disturb/2` implementation that changes the observer's environment.
  """

  defmacro __using__(opts) do
    id = Keyword.fetch!(opts, :id)
    title = Keyword.fetch!(opts, :title)

    quote do
      use AshA2A.Chicago.Court, discoverable: false

      alias AshA2A.Chicago.{Context, Falsifier, Result}
      alias AshA2A.Chicago.Fixtures.ObserverQualification, as: Fx

      @impl true
      def id, do: unquote(id)
      @impl true
      def title, do: unquote(title)
      @impl true
      def gate, do: nil
      @impl true
      def profile, do: :core
      @impl true
      def rfc_sections, do: ["§138"]

      @impl true
      def ocel_mappings, do: [Fx.probe_mapping()]

      @impl true
      def falsifiers do
        [
          Falsifier.new!(
            id: unquote(id) <> "-001",
            court_id: unquote(id),
            kind: :positive_control,
            invariant: "probe events emitted inside the stimulus are observed",
            stimulus: "emit fixture probe events around an observer disturbance",
            boundary: "AshA2A.Chicago.Observer",
            attempt_evidence: "fixture.probe observed",
            attempt_predicate: {:observed, "fixture.probe"},
            outcome_predicate: {:count, "fixture.probe", :gte, 1}
          )
        ]
      end

      @impl true
      def run(%Context{} = ctx) do
        [f] = falsifiers()

        Context.stimulus(ctx, f, fn ->
          for i <- 1..3, do: Fx.probe(%{probe_id: "#{unquote(id)}-pre-#{i}", i: i, label: "pre"})
        end)

        observed =
          ctx
          |> Context.observed(f)
          |> Enum.count(&(&1.activity == "fixture.probe"))

        disturbance = disturb(ctx, f)

        [
          Result.positive(f,
            attempt_observed?: observed > 0,
            expected_outcome_observed?: observed == 3,
            evidence: %{"disturbance" => disturbance, "observed_before" => observed}
          )
        ]
      end
    end
  end
end

defmodule AshA2A.Chicago.Fixtures.ObserverQualification.SteadyCourt do
  @moduledoc "Inner court with no disturbance: the uninterrupted positive control."
  use AshA2A.Chicago.Fixtures.ObserverQualification.InnerCourt,
    id: "SA2A-OCEL-OBSERVER-STEADY",
    title: "uninterrupted observation"

  @doc false
  def disturb(ctx, f) do
    Context.stimulus(ctx, f, fn ->
      for i <- 1..3, do: Fx.probe(%{probe_id: "steady-post-#{i}", i: i, label: "post"})
    end)

    "none"
  end
end

defmodule AshA2A.Chicago.Fixtures.ObserverQualification.OutageCourt do
  @moduledoc """
  Inner court that kills the run's real observer process mid-run, then keeps
  emitting SUT evidence the dead observer cannot record.
  """
  use AshA2A.Chicago.Fixtures.ObserverQualification.InnerCourt,
    id: "SA2A-OCEL-OBSERVER-OUTAGE",
    title: "observer killed mid-run"

  @doc false
  def disturb(ctx, f) do
    observer = GenServer.whereis(ctx.observer)
    ref = Process.monitor(observer)
    Process.exit(observer, :kill)

    receive do
      {:DOWN, ^ref, :process, _, _} -> :ok
    after
      5_000 -> :ok
    end

    Context.stimulus(ctx, f, fn ->
      for i <- 1..3, do: Fx.probe(%{probe_id: "outage-down-#{i}", i: i, label: "while-down"})
    end)

    "killed"
  end
end

defmodule AshA2A.Chicago.Fixtures.ObserverQualification.SuspendCourt do
  @moduledoc """
  Inner court that suspends the run's real observer process (`:sys.suspend/1`)
  while SUT evidence is emitted, then resumes it.
  """
  use AshA2A.Chicago.Fixtures.ObserverQualification.InnerCourt,
    id: "SA2A-OCEL-OBSERVER-SUSPEND",
    title: "observer suspended mid-run"

  @doc false
  def disturb(ctx, f) do
    observer = GenServer.whereis(ctx.observer)

    Context.stimulus(ctx, f, fn ->
      :ok = :sys.suspend(observer)

      try do
        for i <- 1..2, do: Fx.probe(%{probe_id: "suspended-#{i}", i: i, label: "while-suspended"})
      after
        :ok = :sys.resume(observer)
      end
    end)

    "suspended"
  end
end

defmodule AshA2A.Chicago.Fixtures.ObserverQualification.CorruptingValidator do
  @moduledoc """
  OCEL "validator" used as a fault-injection point: the runner calls it after
  the artifact is durably flushed and before the independent consumer loads
  it, and it flips one byte of the real file on disk (an environment fault,
  §10). The runner must then refuse to corroborate anything.
  """

  @spec validate_file(Path.t()) :: {:error, map()}
  def validate_file(path) do
    bytes = File.read!(path)
    offset = div(byte_size(bytes), 2)
    <<pre::binary-size(offset), byte, post::binary>> = bytes
    File.write!(path, <<pre::binary, Bitwise.bxor(byte, 0x01), post::binary>>)
    {:error, %{"fault_injection" => "flipped one bit of byte #{offset} after flush"}}
  end
end

defmodule AshA2A.Chicago.Fixtures.ObserverQualification.LeakingMapping do
  @moduledoc """
  Discrimination fixture for `AshA2A.Chicago.Observer.NonAuthority` (§100):
  a mapping source whose closure reaches into `AshA2A.CommandBus`. The prover
  must refuse it. The closure only reads the configured default store (no
  consequence), and the mapping is never admitted into any run.
  """

  alias AshA2A.Chicago.Fixtures.ObserverQualification, as: Fx
  alias AshA2A.Chicago.Ocel.Mapping

  @spec ocel_mappings() :: [Mapping.t()]
  def ocel_mappings do
    [
      Mapping.new!(
        event: Fx.event(:leak),
        activity: "fixture.leak",
        source: __MODULE__,
        attributes: fn _m, _meta -> %{store: inspect(AshA2A.CommandBus.default_store())} end
      )
    ]
  end
end
