defmodule AshA2A.Chicago.Fixtures.AutonomyBounds.Domain do
  @moduledoc "Ash domain for the autonomy (CHI-AUTO) and resource-bounds (SA2A-BOUNDS) court fixtures."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshA2A.Chicago.Fixtures.AutonomyBounds.Step)
  end
end

defmodule AshA2A.Chicago.Fixtures.AutonomyBounds.Step do
  @moduledoc """
  The real actuators an autonomous episode drives, each reachable only as a
  skill through `AshA2A.CommandBus`:

    * `record_step` (`:change`) -- writes one `Step` row, optionally after
      sleeping `delay_ms` inside the actuation (runtime/concurrency courts);
    * `call_external` (`:external_do`) -- writes one `external` row;
    * `do_work` (`:change`, generic action) -- a worker that records every
      attempt as a row, then succeeds, fails (`mode: "fail"`), or reports it
      needs more model tokens (`mode: "need_more"`).

  Rows are read back by the courts through `Ash.read!/1` -- an independent
  post-state reader, not the receipt, the reply or the episode result.
  """
  use Ash.Resource,
    domain: AshA2A.Chicago.Fixtures.AutonomyBounds.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:episode_tag, :string, public?: true, allow_nil?: false)
    attribute(:label, :string, public?: true, allow_nil?: false)
    attribute(:kind, :string, public?: true, allow_nil?: false, default: "record")
  end

  actions do
    defaults([:read])

    create :record do
      accept([:episode_tag, :label])
      argument(:delay_ms, :integer, default: 0)

      change(fn changeset, _context ->
        case Ash.Changeset.get_argument(changeset, :delay_ms) do
          ms when is_integer(ms) and ms > 0 -> Process.sleep(ms)
          _ -> :ok
        end

        changeset
      end)
    end

    create :external do
      accept([:episode_tag, :label])
      change(set_attribute(:kind, "external"))
    end

    action :work, :map do
      argument(:episode_tag, :string, allow_nil?: false)
      argument(:label, :string, allow_nil?: false)
      argument(:mode, :string, default: "ok")
      argument(:need_tokens, :integer, default: 0)

      run(fn input, _context ->
        args = input.arguments

        AshA2A.Chicago.Fixtures.AutonomyBounds.Step
        |> Ash.Changeset.for_create(:record, %{
          episode_tag: args.episode_tag,
          label: "#{args.label}:attempt:#{args.mode}"
        })
        |> Ash.create!()

        case args.mode do
          "fail" -> {:error, "transient worker failure"}
          "need_more" -> {:ok, %{"need_more_resources" => %{"tokens" => args.need_tokens}}}
          _ -> {:ok, %{"status" => "done"}}
        end
      end)
    end
  end

  a2a do
    skill(:record_step, :record)
    skill(:call_external, :external, consequence: :external_do)
    skill(:do_work, :work, consequence: :change)
  end
end

defmodule AshA2A.Chicago.Fixtures.AutonomyBounds do
  @moduledoc """
  Shared fixtures for `AshA2A.Chicago.Courts.AutonomousExecution` (`CHI-AUTO`)
  and `AshA2A.Chicago.Courts.ResourceBounds` (`SA2A-BOUNDS`).

  Everything drives real collaborators: the real `AshA2A.Semantic.Episode`
  executor and its ledger, real `AshA2A.Semantic.Admission` over real source
  text, the real `hddl_cli` planner, the real `AshA2A.CommandBus`, a real
  `AshA2A.ReceiptStore.Memory`, a real `AshA2A.Authority.Broker.InMemory`, and
  the real ETS `Step` resource. Evidence readers over the observer's records
  are reused from `AshA2A.Chicago.Fixtures.HooksCascade`.
  """

  alias AshA2A.Authority.Broker.InMemory
  alias AshA2A.Authority.Grant
  alias AshA2A.Chicago.Fixtures.HooksCascade
  alias AshA2A.Chicago.Ocel.Mapping
  alias AshA2A.Identity

  alias AshA2A.Semantic.{
    Admission,
    Episode,
    IR,
    Ontology,
    PlanningIR,
    PlanPackage,
    PlanProjection
  }

  alias AshA2A.Semantic.Source
  alias __MODULE__.Step

  @record "AshA2A.Chicago.Fixtures.AutonomyBounds.Step.record"
  @external "AshA2A.Chicago.Fixtures.AutonomyBounds.Step.external"
  @work "AshA2A.Chicago.Fixtures.AutonomyBounds.Step.work"

  @spec record_capability() :: String.t()
  def record_capability, do: @record
  @spec external_capability() :: String.t()
  def external_capability, do: @external
  @spec work_capability() :: String.t()
  def work_capability, do: @work
  @spec capabilities() :: [String.t()]
  def capabilities, do: [@record, @external, @work]

  # --- environment ---------------------------------------------------------------

  @doc """
  Starts a real receipt store and authority broker. `granted` holds every
  fixture capability; `limited` holds only `record_step`; `escalated` holds
  every capability (used to prove a subtask cannot borrow it). Runs
  `fun.(env)` and stops both.
  """
  @spec with_env((map() -> result)) :: result when result: var
  def with_env(fun) do
    n = System.unique_integer([:positive])
    store_name = Module.concat(__MODULE__, "Store#{n}")
    broker_name = Module.concat(__MODULE__, "Broker#{n}")
    {:ok, store} = AshA2A.ReceiptStore.Memory.start_link(name: store_name)
    {:ok, broker} = InMemory.start_link(name: broker_name)

    env = %{
      nonce: n,
      store_opts: [name: store_name],
      broker: {InMemory, [name: broker_name]},
      granted: "episode-granted-#{n}",
      limited: "episode-limited-#{n}",
      escalated: "episode-escalated-#{n}"
    }

    for {principal, caps} <- [
          {env.granted, capabilities()},
          {env.limited, [@record]},
          {env.escalated, capabilities()}
        ],
        cap <- caps do
      {:ok, _} = Grant.grant(Identity.principal(principal), cap, broker: env.broker)
    end

    try do
      fun.(env)
    after
      for pid <- [store, broker], Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  # --- admitted semantics and the real planner inputs -------------------------------

  @source_text """
  The meeting opens and the facilitator must advance the room through every
  phase in order until it can close. The room starts at the open phase.
  The facilitator can advance the room from one phase to the next phase.
  """

  @doc "Admitted IR and ontology from real `Admission.admit/2` over real source text."
  @spec admitted() :: {IR.t(), Ontology.t()}
  def admitted do
    source = Source.new(@source_text, id: "sa2a-autonomy-src-1")

    candidate = %IR{
      source_id: source.id,
      standing: :candidate,
      authority: :none,
      entities: [
        %{
          "id" => "room",
          "kind" => "entity",
          "type" => "schema:Place",
          "label" => "the room",
          "description" => "the room being advanced through phases",
          "source_quote" => "the room"
        },
        %{
          "id" => "facilitator",
          "kind" => "entity",
          "type" => "schema:Person",
          "label" => "the facilitator",
          "description" => "the person advancing the room",
          "source_quote" => "the facilitator"
        }
      ],
      relations: [
        %{
          "id" => "rel-advance",
          "kind" => "relation",
          "subject" => "facilitator",
          "predicate" => "schema:agent",
          "object" => "room",
          "description" => "the facilitator advances the room",
          "source_quote" => "advance the room"
        }
      ],
      goals: [
        %{
          "id" => "goal-close",
          "kind" => "goal",
          "description" => "advance the room through every phase until it can close",
          "source_quote" => "advance the room through every"
        }
      ],
      capabilities: [
        %{
          "id" => "cap-advance",
          "kind" => "capability",
          "description" => "advance the room from one phase to the next phase",
          "source_quote" => "advance the room from one phase to the next phase"
        }
      ],
      observations: [
        %{
          "id" => "obs-open",
          "kind" => "observation",
          "description" => "the room starts at the open phase",
          "source_quote" => "The room starts at the open phase"
        }
      ]
    }

    with {:ok, ir} <- Admission.admit(source, candidate),
         {:ok, ontology} <- Ontology.from_ir(ir) do
      {ir, ontology}
    else
      {:error, refusal} -> raise ArgumentError, "fixture semantics refused: #{inspect(refusal)}"
    end
  end

  @doc "The real derived planning projection over `admitted/0`."
  @spec projection() :: PlanProjection.t()
  def projection do
    {ir, ontology} = admitted()
    {:ok, planning} = PlanningIR.from_ir(ir, ontology)
    {:ok, projection} = PlanProjection.from_admitted(planning, ontology)
    projection
  end

  @spec domain_hddl() :: String.t()
  def domain_hddl do
    """
    (define (domain sa2a-episode-meeting)
      (:types phase)
      (:predicates (current-phase ?p - phase))
      (:task run-meeting :parameters (?start - phase))
      (:action advance
        :parameters (?from - phase ?to - phase)
        :precondition (current-phase ?from)
        :effect (and (not (current-phase ?from)) (current-phase ?to)))
      (:method m-run-meeting
        :parameters (?start - phase)
        :task (run-meeting ?start)
        :ordered-subtasks (and
          (t1 (advance open trust))
          (t2 (advance trust clean))
          (t3 (advance clean help))
          (t4 (advance help fellowship))
          (t5 (advance fellowship close)))))
    """
  end

  @spec problem_hddl() :: String.t()
  def problem_hddl do
    """
    (define (problem sa2a-episode-meeting-p1)
      (:domain sa2a-episode-meeting)
      (:objects open trust clean help fellowship close - phase)
      (:htn :parameters () :ordered-subtasks (and (m1 (run-meeting open))))
      (:init (current-phase open))
      (:goal (and (current-phase close))))
    """
  end

  @doc "Strict `PlanPackage.from_projection/3` options over the fixture capabilities."
  @spec package_opts(keyword()) :: keyword()
  def package_opts(overrides \\ []) do
    Keyword.merge(
      [
        profile: :strict,
        planning_domain_identity: "sa2a-episode-meeting",
        method_identities: ["m-run-meeting"],
        action_identities: [],
        preconditions: [{:"current-phase", [:open]}],
        effects: [{:"current-phase", [:close]}],
        consequence_class: :change,
        required_capabilities: capabilities(),
        max_fan_out: 8,
        max_depth: 16,
        max_parallelism: 8,
        resource_envelope: %{
          max_wall_ms: 60_000,
          max_memory_bytes: 1_000_000_000,
          max_invocations: 64
        },
        authority_requirements: [%{capability_id: @record, mode: :required}],
        receipt_obligations: [:do_receipt]
      ],
      overrides
    )
  end

  @doc """
  A strict package whose plan body is `n` static action identities
  (`"step:1"..`), admitted by the real `PlanPackage.from_projection/3`. Used
  by bound courts that qualify the executor, not the planner.
  """
  @spec static_package!(PlanProjection.t(), pos_integer(), keyword()) :: PlanPackage.t()
  def static_package!(projection, n, overrides \\ []) do
    opts = package_opts(Keyword.merge([action_identities: steps(n)], overrides))

    case PlanPackage.from_projection(projection, "court-fixture:static-plan", opts) do
      {:ok, package} -> package
      {:error, refusal} -> raise ArgumentError, "fixture package refused: #{inspect(refusal)}"
    end
  end

  @spec steps(non_neg_integer()) :: [String.t()]
  def steps(0), do: []
  def steps(n), do: Enum.map(1..n, &"step:#{&1}")

  # --- envelopes, bindings, runs ----------------------------------------------------

  @generous [
    fan_out: 8,
    depth: 16,
    parallelism: 8,
    executions: 64,
    memory_bytes: 1_000_000_000,
    tokens: 1_000_000,
    money_micros: 10_000_000,
    external_requests: 64,
    retries: 8,
    wall_time_ms: 120_000
  ]

  @doc "Every envelope dimension at a generous finite ceiling, overridden by `overrides`."
  @spec envelope_spec(keyword()) :: keyword()
  def envelope_spec(overrides \\ []),
    do: Keyword.merge(@generous ++ [capabilities: capabilities()], overrides)

  @doc "Issues a host envelope; raises if the ledger refuses the spec."
  @spec envelope!(keyword()) :: Episode.Envelope.t()
  def envelope!(overrides \\ []) do
    case Episode.issue({:host, :sa2a_chicago_court}, envelope_spec(overrides)) do
      {:ok, envelope} -> envelope
      {:error, refusal} -> raise ArgumentError, "fixture envelope refused: #{inspect(refusal)}"
    end
  end

  @doc "A bounded control contract (never-satisfied predicate unless overridden)."
  @spec control(keyword()) :: keyword()
  def control(overrides \\ []) do
    Keyword.merge(
      [termination: fn _view -> false end, max_steps: 64, max_wall_time_ms: 60_000],
      overrides
    )
  end

  @doc """
  A binding for `"step:N"` identities: `fun.(n)` returns a transition spec
  (see `record/3`, `work/3`, `external/3`).
  """
  @spec bind((pos_integer() -> map())) :: (String.t() -> {:ok, map()} | {:error, term()})
  def bind(fun) do
    fn
      "step:" <> n ->
        case Integer.parse(n) do
          {i, ""} -> {:ok, fun.(i)}
          _ -> {:error, {:unbound, n}}
        end

      other ->
        {:error, {:unbound, other}}
    end
  end

  @spec record(String.t(), pos_integer(), keyword()) :: map()
  def record(tag, n, opts \\ []),
    do:
      spec(
        @record,
        %{
          "episode_tag" => tag,
          "label" => "step-#{n}",
          "delay_ms" => Keyword.get(opts, :delay_ms, 0)
        },
        n,
        opts
      )

  @spec external(String.t(), pos_integer(), keyword()) :: map()
  def external(tag, n, opts \\ []),
    do: spec(@external, %{"episode_tag" => tag, "label" => "external-#{n}"}, n, opts)

  @spec work(String.t(), pos_integer(), keyword()) :: map()
  def work(tag, n, opts \\ []) do
    spec(
      @work,
      %{
        "episode_tag" => tag,
        "label" => "work-#{n}",
        "mode" => Keyword.get(opts, :mode, "ok"),
        "need_tokens" => Keyword.get(opts, :need_tokens, 0)
      },
      n,
      opts
    )
  end

  defp spec(capability, input, n, opts) do
    %{
      capability_id: capability,
      input: input,
      stage: Keyword.get(opts, :stage, n),
      cost: Keyword.get(opts, :cost, %{})
    }
  end

  @doc """
  Runs one real episode. `opts`: `:principal` (default `env.granted`),
  `:bind`, `:control`, `:parallelism`, `:parent`.
  """
  @spec run!(PlanPackage.t(), Episode.Envelope.t(), map(), keyword()) :: Episode.Result.t()
  def run!(package, envelope, env, opts) do
    run_opts =
      [
        principal: Keyword.get(opts, :principal, env.granted),
        resource_or_domain: Step,
        bind: Keyword.fetch!(opts, :bind),
        control: Keyword.get_lazy(opts, :control, fn -> control() end),
        authority_opts: [policy: :broker, broker: env.broker],
        store: AshA2A.ReceiptStore.Memory,
        store_opts: env.store_opts,
        agent_id: "sa2a-episode-court"
      ] ++ Keyword.take(opts, [:parallelism, :parent])

    case Episode.run(package, envelope, run_opts) do
      {:ok, result} -> result
      {:error, refusal} -> raise ArgumentError, "episode refused its options: #{inspect(refusal)}"
    end
  end

  @doc "Independent post-state reader: every `Step` row for `tag`, oldest first by label."
  @spec rows(String.t()) :: [struct()]
  def rows(tag), do: Step |> Ash.read!() |> Enum.filter(&(&1.episode_tag == tag))

  @spec labels(String.t()) :: [String.t()]
  def labels(tag), do: tag |> rows() |> Enum.map(& &1.label) |> Enum.sort()

  # --- OCEL -----------------------------------------------------------------------

  @activities [
    {[:planning], "episode.planning"},
    {[:allocation], "episode.allocation"},
    {[:start], "episode.start"},
    {[:admission], "episode.admission"},
    {[:transition, :request], "episode.transition.request"},
    {[:bound], "episode.bound"},
    {[:transition, :start], "episode.transition.start"},
    {[:transition, :stop], "episode.transition.stop"},
    {[:stop], "episode.stop"}
  ]

  @attribute_keys [
    :outcome,
    :code,
    :kind,
    :phase,
    :resource,
    :requested,
    :ceiling,
    :stage,
    :seq,
    :attempt,
    :in_flight,
    :authority,
    :authority_us,
    :do_us,
    :duration_us,
    :resource_request,
    :child_outcome,
    :plan_size,
    :requested_parallelism,
    :requested_executions,
    :carries_authority,
    :stages,
    :stages_total,
    :stages_run,
    :committed,
    :retries,
    :executions_used,
    :extension,
    :contract_max_steps,
    :contract_max_wall_time_ms,
    :depth_ceiling,
    :fan_out_ceiling,
    :parallelism_ceiling,
    :executions_ceiling,
    :memory_ceiling,
    :wall_ceiling_ms,
    :memory_peak_bytes,
    :issuer,
    :planner,
    :methods,
    :goals,
    :objects,
    :profile,
    :max_fan_out,
    :max_depth,
    :max_parallelism,
    :max_wall_ms,
    :max_memory_bytes,
    :max_invocations,
    :capability_id,
    :action_identity
  ]

  @doc """
  OCEL mappings for `[:ash_a2a, :episode, ...]` telemetry. Object types:
  `episode`, `envelope` (qualifiers `envelope` / `parent_envelope`),
  `plan` (plan digest), `planning`, `command` (shared with the `brce.*`
  activities, so a transition and the command CommandBus decided are one
  object), `receipt`. The source is this fixture module, so both courts
  declaring the set admit it once.
  """
  @spec mappings() :: [Mapping.t()]
  def mappings do
    objects = fn _m, meta ->
      [
        {"episode", meta[:episode_id], "episode"},
        {"episode", meta[:child_episode_id], "child_episode"},
        {"envelope", meta[:envelope_id], "envelope"},
        {"envelope", meta[:parent_envelope_id], "parent_envelope"},
        {"plan", meta[:plan_digest], "plan"},
        {"planning", meta[:planning_id], "planning"},
        {"command", meta[:command_id], "command"},
        {"receipt", meta[:receipt_id], "receipt"}
      ]
    end

    attributes = fn _m, meta -> Map.take(meta, @attribute_keys) end

    for {suffix, activity} <- @activities do
      Mapping.new!(
        event: [:ash_a2a, :episode | suffix],
        activity: activity,
        source: __MODULE__,
        objects: objects,
        attributes: attributes
      )
    end
  end

  # --- evidence readers (shared with the hook courts) ---------------------------------

  defdelegate records(ctx, falsifier, activity, attrs \\ %{}), to: HooksCascade
  defdelegate seen?(ctx, falsifier, activity, attrs \\ %{}), to: HooksCascade
  defdelegate count(ctx, falsifier, activity, attrs \\ %{}), to: HooksCascade
  defdelegate object(record, type), to: HooksCascade
  defdelegate stats(values), to: HooksCascade
  defdelegate guarded(falsifier, fun), to: HooksCascade
  defdelegate actuation_overlap(records, command_ids \\ nil), to: HooksCascade
end
