defmodule AshA2A.Chicago.Fixtures.PlanGates do
  @moduledoc """
  Real planning material for the `CHI-PLAN-AUTH` (Gate 4), `CHI-PREFLIGHT`
  (Gate 5) and `SA2A-PLAN` (§58, §59) courts.

  Nothing here is a stub. The admitted IR goes through the real
  `AshA2A.Semantic.Admission.admit/2` (its `source_quote` grounding check
  against a real `AshA2A.Semantic.Source`), the ontology and planning IR are
  the real projections, `AshA2A.Semantic.PlanProjection.from_admitted/2`
  derives the projection, `AshA2A.Semantic.PlanPackage.from_projection/3`
  manufactures the strict package, `AshA2A.Semantic.Select` and
  `AshA2A.Semantic.Construct` choose and construct it, and
  `AshA2A.Planning.Preflight` preflights the whole bounded plan.

  The plan's steps execute the real consequence-bearing capabilities of
  `AshA2A.Chicago.Fixtures.Brce.Planned` (`advance`: `:change`, `unlock`:
  `:external_do`), whose real Ash actions write rows an independent reader
  (`consequence_rows/1`) counts. Every plan is unique per token: the token
  names the phases the plan's preconditions/effects and step inputs carry.

  The admitted source mirrors `test/support/sa2a_plan_fixture.ex` (lib code
  cannot reference `test/support`).
  """

  alias AshA2A.{Authority, Command, Identity}
  alias AshA2A.Chicago.Courts.Brce
  alias AshA2A.Chicago.Fixtures.Brce, as: BrceFx
  alias AshA2A.Chicago.Fixtures.Brce.Planned
  alias AshA2A.Chicago.Ocel.Mapping
  alias AshA2A.Planning.{BoundedPlan, Preflight}

  alias AshA2A.Semantic.{
    Admission,
    Construct,
    IR,
    Ontology,
    PlanningIR,
    PlanPackage,
    PlanProjection,
    Select,
    Source
  }

  @source_text """
  The meeting opens and the facilitator must advance the room through every
  phase in order until it can close. The room starts at the open phase.
  The facilitator can advance the room from one phase to the next phase.
  Attendance may vary, so the room count is unclear at the start.
  No phase may be skipped.
  """

  @planner_identity "hddl_cli@native/hddl_cli"
  @manufacturer_identity "AshA2A.Chicago.Fixtures.PlanGates.manufacture/1"
  @manufacturer_version "v26.9.16"

  # --- admitted semantics -----------------------------------------------------

  @spec source() :: Source.t()
  def source, do: Source.new(@source_text, id: "chicago-plan-gates-src-1")

  @spec candidate_ir() :: IR.t()
  def candidate_ir do
    %IR{
      source_id: source().id,
      standing: :candidate,
      authority: :none,
      entities: [
        entity("room", "schema:Place", "the room"),
        entity("facilitator", "schema:Person", "the facilitator")
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
      events: [],
      goals: [
        item(
          "goal-close",
          "goal",
          "advance the room through every phase until it can close",
          "advance the room through every"
        )
      ],
      constraints: [
        item("constraint-order", "constraint", "phases must be advanced in order", "in order")
      ],
      capabilities: [
        item(
          "cap-advance",
          "capability",
          "advance the room from one phase to the next phase",
          "advance the room from one phase to the next phase"
        )
      ],
      authorities: [],
      observations: [
        item(
          "obs-open",
          "observation",
          "the room starts at the open phase",
          "The room starts at the open phase"
        )
      ],
      uncertainties: [
        item(
          "unc-count",
          "uncertainty",
          "the room count is unclear at the start",
          "the room count is unclear"
        )
      ],
      exclusions: [
        item("excl-skip", "exclusion", "no phase may be skipped", "No phase may be skipped")
      ],
      temporal_relations: [],
      causal_hypotheses: [],
      unresolved: []
    }
  end

  defp entity(id, type, label) do
    %{
      "id" => id,
      "kind" => "entity",
      "type" => type,
      "label" => label,
      "description" => label,
      "source_quote" => label
    }
  end

  defp item(id, kind, description, quote) do
    %{"id" => id, "kind" => kind, "description" => description, "source_quote" => quote}
  end

  @doc "`{projection, ontology}` derived from the really-admitted IR. Raises on refusal."
  @spec projection() :: {PlanProjection.t(), Ontology.t()}
  def projection do
    {:ok, %IR{standing: :admitted} = ir} = Admission.admit(source(), candidate_ir())
    {:ok, ontology} = Ontology.from_ir(ir)
    {:ok, planning} = PlanningIR.from_ir(ir, ontology)
    {:ok, projection} = PlanProjection.from_admitted(planning, ontology)
    {projection, ontology}
  end

  # --- plan package -----------------------------------------------------------

  @spec planner_identity() :: String.t()
  def planner_identity, do: @planner_identity

  @doc "Real capability ids of `Planned.advance` / `Planned.unlock`."
  @spec capability_ids() :: [String.t()]
  def capability_ids do
    for name <- [:advance, :unlock] do
      {:ok, skill} = AshA2A.Info.skill(Planned, name)
      skill.id
    end
  end

  @spec token() :: String.t()
  def token, do: Integer.to_string(System.unique_integer([:positive]))

  @spec phases(String.t()) :: {String.t(), String.t()}
  def phases(token), do: {"pa#{token}", "pb#{token}"}

  @doc "Every `PlanPackage.from_projection/3` option for a strict package over `token`."
  @spec package_opts(String.t(), keyword()) :: keyword()
  def package_opts(token, overrides \\ []) do
    {from, to} = phases(token)
    [advance, unlock] = capability_ids()

    Keyword.merge(
      [
        profile: :strict,
        planning_domain_identity: "chicago-plan-gates-domain",
        method_identities: ["m-advance-and-unlock"],
        action_identities: ["advance", "unlock"],
        preconditions: [{:current_phase, [from]}],
        effects: [{:current_phase, [to]}, {:has_key, [to]}],
        nondeterministic_outcomes: [],
        consequence_class: :external_do,
        required_capabilities: [advance, unlock],
        max_fan_out: 8,
        max_depth: 8,
        max_parallelism: 4,
        resource_envelope: %{
          max_wall_ms: 60_000,
          max_memory_bytes: 64_000_000,
          max_invocations: 64
        },
        authority_requirements: authority_requirements(),
        receipt_obligations: [:construction_receipt, :do_receipt]
      ],
      overrides
    )
  end

  @spec authority_requirements() :: [map()]
  def authority_requirements do
    for id <- capability_ids(), do: %{capability_id: id, mode: :required, scope: "room"}
  end

  @spec package(PlanProjection.t(), String.t(), keyword()) ::
          {:ok, PlanPackage.t()} | {:error, map()}
  def package(projection, token, overrides \\ []),
    do: PlanPackage.from_projection(projection, @planner_identity, package_opts(token, overrides))

  # --- SELECT / CONSTRUCT -----------------------------------------------------

  @doc "Real SELECT among `candidates`, lowest `max_fan_out` (a cost) wins."
  @spec select([PlanPackage.t()]) :: {:ok, AshA2A.Semantic.Selection.t()} | {:error, map()}
  def select(candidates) do
    Select.select(candidates, & &1.max_fan_out,
      profile: :strict,
      selector_identity: "chicago-plan-gates-cost-optimizer"
    )
  end

  @doc "Real CONSTRUCT of the plan's executable steps from the package."
  @spec construct(PlanPackage.t(), PlanProjection.t()) ::
          {:ok, AshA2A.Semantic.Construction.t()} | {:error, map()}
  def construct(package, projection) do
    Construct.construct(package, projection, &manufacture/1,
      manufacturer_identity: @manufacturer_identity,
      manufacturer_version: @manufacturer_version
    )
  end

  @doc """
  The manufacturer: derives the ordered plan steps from the package's own
  preconditions, effects and required capabilities.
  """
  @spec manufacture(PlanPackage.t()) :: {:ok, [BoundedPlan.step()]} | {:error, term()}
  def manufacture(%PlanPackage{} = package) do
    with [{_, [from]} | _] <- package.preconditions,
         [{_, [to]} | _] <- package.effects,
         [advance, unlock] <- package.required_capabilities do
      {:ok,
       [
         %{capability_id: advance, input: %{"from" => from, "to" => to}},
         %{capability_id: unlock, input: %{"who" => to}}
       ]}
    else
      other -> {:error, {:unmanufacturable_package, inspect(other, limit: 5)}}
    end
  end

  # --- bounded plan -------------------------------------------------------------

  @doc "The whole bounded plan over a constructed package."
  @spec bounded_plan(PlanPackage.t(), AshA2A.Semantic.Construction.t(), keyword()) ::
          BoundedPlan.t()
  def bounded_plan(package, construction, overrides \\ []) do
    struct!(
      BoundedPlan,
      Keyword.merge(
        [
          plan_package: package,
          steps: construction.artifact,
          fan_out: 2,
          cascade_depth: 1,
          parallelism: 1,
          retry_count: 0,
          resource_budget: %{max_invocations: 8, max_wall_ms: 30_000, max_external_requests: 2},
          external_request_count: 1,
          financial_envelope: %{currency: "USD", max_minor_units: 0},
          authority_requirement: package.authority_requirements,
          semantic_subject: construction.semantic_subject
        ],
        overrides
      )
    )
  end

  @typedoc "A fully planned, selected, constructed and preflighted candidate."
  @type planned :: %{
          token: String.t(),
          projection: PlanProjection.t(),
          package: PlanPackage.t(),
          selection: AshA2A.Semantic.Selection.t(),
          construction: AshA2A.Semantic.Construction.t(),
          plan: BoundedPlan.t(),
          preflight: Preflight.t()
        }

  @doc """
  Runs the whole candidate pipeline for a fresh token: two strict packages
  (different cost), SELECT, CONSTRUCT, bounded plan, preflight. Raises if any
  real stage refuses -- a fixture that stopped being plannable fails loudly.
  """
  @spec planned(String.t()) :: planned()
  def planned(token \\ token()) do
    {projection, _ontology} = projection()
    {:ok, cheap} = package(projection, token)
    {:ok, costly} = package(projection, token, max_fan_out: 16)
    {:ok, selection} = select([costly, cheap])
    {:ok, construction} = construct(selection.chosen, projection)
    plan = bounded_plan(selection.chosen, construction)
    {:ok, preflight} = Preflight.preflight(plan)

    %{
      token: token,
      projection: projection,
      package: selection.chosen,
      selection: selection,
      construction: construction,
      plan: plan,
      preflight: preflight
    }
  end

  @doc "HDDL goal facts whose task_sequence is the plan's steps (for the real hddl_cli)."
  @spec goal_facts(String.t()) :: map()
  def goal_facts(token) do
    {from, to} = phases(token)
    [advance, unlock] = capability_ids()

    %{
      "request_id" => "chicago-plan-gates-#{token}",
      "domain_name" => "chicago-plan-gates-domain",
      "problem_name" => "chicago-plan-gates-problem-#{token}",
      "objects" => [from, to],
      "init" => [%{"predicate" => "current_phase", "args" => [from]}],
      "goal" => [
        %{"predicate" => "current_phase", "args" => [to]},
        %{"predicate" => "has_key", "args" => [to]}
      ],
      "task_sequence" => [
        %{"capability_id" => advance, "args" => [from, to]},
        %{"capability_id" => unlock, "args" => [to]}
      ]
    }
  end

  # --- step execution material ------------------------------------------------

  @spec principal() :: Identity.t()
  def principal, do: Identity.principal("chicago-plan-gates-executor")

  @doc """
  The real `AshA2A.Command` for one plan step. `authority:` is `:none` (no
  authority), `:granted` (a real `AshA2A.Authority` for the principal and
  capability), or any term placed verbatim in the authority slot.
  """
  @spec step_command(BoundedPlan.step(), keyword()) :: Command.t()
  def step_command(%{capability_id: capability_id, input: input}, opts \\ []) do
    principal = Keyword.get(opts, :principal, principal())

    authority =
      case Keyword.get(opts, :authority, :none) do
        :none -> nil
        :granted -> Authority.new(principal, capability_id)
        other -> other
      end

    Command.new(capability_id,
      command_id: "chicago-plan-gates-" <> Ash.UUIDv7.generate(),
      agent_id: "chicago-plan-gates-agent",
      principal_id: principal,
      authority: authority,
      input: input,
      metadata: Map.new(Keyword.get(opts, :metadata, %{}))
    )
  end

  @spec step_message(BoundedPlan.step()) :: A2A.Message.t()
  def step_message(%{input: input}), do: A2A.Message.new_user([A2A.Part.Data.new(input)])

  @doc "Independent reader: persisted consequence rows (ledger + external) naming `token`."
  @spec consequence_rows(String.t()) :: non_neg_integer()
  def consequence_rows(token) do
    Enum.count(BrceFx.ledger_labels() ++ BrceFx.effect_labels(), &String.contains?(&1, token))
  end

  @doc "Runs `fun` with a fresh real `AshA2A.ReceiptStore.Memory` process."
  @spec with_store((keyword() -> result)) :: result when result: var
  def with_store(fun) do
    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    {:ok, pid} = AshA2A.ReceiptStore.Memory.start_link(name: name)

    try do
      fun.(store: AshA2A.ReceiptStore.Memory, store_opts: [name: name])
    after
      if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  @doc """
  Runs `fun` with a fresh real `AshA2A.Authority.Broker.InMemory` configured
  as the authority broker, holding exactly `grants` (`[{principal_value,
  capability}]`). The previous authority configuration is restored after.
  """
  @spec with_broker([{String.t(), String.t()}], (-> result)) :: result when result: var
  def with_broker(grants, fun) do
    name = Module.concat(__MODULE__, "Broker#{System.unique_integer([:positive])}")
    {:ok, pid} = AshA2A.Authority.Broker.InMemory.start_link(name: name)
    previous_policy = Application.fetch_env(:ash_a2a, :authority_policy)
    previous_broker = Application.fetch_env(:ash_a2a, :authority_broker)
    Application.put_env(:ash_a2a, :authority_policy, :broker)

    Application.put_env(
      :ash_a2a,
      :authority_broker,
      {AshA2A.Authority.Broker.InMemory, [name: name]}
    )

    try do
      for {who, capability} <- grants do
        {:ok, %Authority{}} = AshA2A.Authority.Grant.grant(Identity.principal(who), capability)
      end

      fun.()
    after
      restore_env(:authority_policy, previous_policy)
      restore_env(:authority_broker, previous_broker)
      if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:ash_a2a, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:ash_a2a, key)

  # --- in-run evidence (the durable verdict is re-derived from OCEL) ----------

  @actuations ["brce.actuate.start", "dispatch.actuate"]

  @doc "OCEL predicate: any actuation at the BRCE boundary or the dispatcher."
  @spec actuation_predicate() :: AshA2A.Chicago.Query.predicate()
  def actuation_predicate, do: {:any, Enum.map(@actuations, &{:observed, &1})}

  @doc "OCEL predicate: prepared ≺ actuated ≺ committed on the same command and receipt."
  @spec receipted_do_predicate() :: AshA2A.Chicago.Query.predicate()
  def receipted_do_predicate do
    {:all,
     [
       {:observed, "brce.prepare", %{"outcome" => "prepared"}},
       {:precedes, "brce.prepare", "brce.actuate.start", "command"},
       {:precedes, "brce.prepare", "dispatch.actuate", "receipt"},
       {:precedes, "brce.actuate.start", "brce.commit", "command"},
       {:observed, "brce.commit", %{"outcome" => "committed"}}
     ]}
  end

  @doc "True when the observer recorded `activity` with every `attrs` value for `falsifier`."
  @spec observed?(AshA2A.Chicago.Context.t(), term(), String.t(), map()) :: boolean()
  def observed?(ctx, falsifier, activity, attrs \\ %{}) do
    ctx
    |> AshA2A.Chicago.Context.observed(falsifier)
    |> Enum.any?(fn record ->
      record.activity == activity and
        Enum.all?(attrs, fn {k, v} -> to_string(record.attributes[k]) == v end)
    end)
  end

  @doc "Attribute values of every `activity` record attributed to `falsifier`."
  @spec attr_values(AshA2A.Chicago.Context.t(), term(), String.t(), String.t()) :: [String.t()]
  def attr_values(ctx, falsifier, activity, attr) do
    for record <- AshA2A.Chicago.Context.observed(ctx, falsifier), record.activity == activity do
      to_string(record.attributes[attr])
    end
  end

  @spec actuated?(AshA2A.Chicago.Context.t(), term()) :: boolean()
  def actuated?(ctx, falsifier), do: Enum.any?(@actuations, &observed?(ctx, falsifier, &1))

  @doc "In-run form of `receipted_do_predicate/0`: every actuation follows its own preparation."
  @spec receipted_do?(AshA2A.Chicago.Context.t(), term()) :: boolean()
  def receipted_do?(ctx, falsifier) do
    records = AshA2A.Chicago.Context.observed(ctx, falsifier)
    prepares = Enum.filter(records, &(&1.activity == "brce.prepare"))
    actuations = Enum.filter(records, &(&1.activity in @actuations))

    actuations != [] and
      Enum.all?(actuations, fn actuation ->
        receipt = object_id(actuation, "receipt")

        receipt != nil and
          Enum.any?(prepares, &(&1.seq < actuation.seq and object_id(&1, "receipt") == receipt))
      end) and
      Enum.any?(
        records,
        &(&1.activity == "brce.commit" and &1.attributes["outcome"] == "committed")
      )
  end

  defp object_id(record, type) do
    Enum.find_value(record.objects, fn
      {^type, id, _qualifier} -> id
      _ -> nil
    end)
  end

  @doc """
  Runs one falsifier's execution so a raising stimulus cannot sink its
  sibling falsifiers. A raise is never a pass: a negative whose stimulus
  actuated before raising SURVIVES; anything else is UNKNOWN (§130).
  """
  @spec fenced(AshA2A.Chicago.Context.t(), AshA2A.Chicago.Falsifier.t(), (-> result)) ::
          result
        when result: AshA2A.Chicago.Result.t()
  def fenced(ctx, falsifier, fun) do
    fun.()
  rescue
    exception -> raised(ctx, falsifier, Exception.format_banner(:error, exception))
  catch
    kind, reason -> raised(ctx, falsifier, Exception.format_banner(kind, reason))
  end

  defp raised(ctx, %AshA2A.Chicago.Falsifier{kind: :negative} = f, banner) do
    if actuated?(ctx, f) do
      AshA2A.Chicago.Result.negative(f,
        attempt_observed?: observed?(ctx, f, "brce.target", %{"outcome" => "resolved"}),
        forbidden_outcome_observed?: true,
        detail: "stimulus raised after actuation: " <> banner
      )
    else
      AshA2A.Chicago.Result.unknown(f, "stimulus raised: " <> banner, :ocel_evidence_incomplete)
    end
  end

  defp raised(_ctx, falsifier, banner),
    do:
      AshA2A.Chicago.Result.unknown(
        falsifier,
        "stimulus raised: " <> banner,
        :ocel_evidence_incomplete
      )

  @doc "`\"ok\"` or the refusal code of a `CommandBus.run/4` / agent reply."
  @spec reply_code(term()) :: String.t()
  def reply_code({:ok, _}), do: "ok"
  def reply_code({:error, %{code: code}}), do: to_string(code)
  def reply_code(other), do: inspect(other, limit: 6, printable_limit: 200)

  # --- OCEL mappings (shared by the three courts; admitted once) --------------

  @reused_brce_events [
    [:ash_a2a, :dispatch, :actuate],
    [:ash_a2a, :dispatch, :brce_gate],
    [:ash_a2a, :agent, :dispatch],
    [:ash_a2a, :planning, :admit]
  ]

  @doc """
  OCEL mappings the plan courts rely on: the `CHI-BRCE` mappings for dispatcher
  actuation, agent routing and planning admission (reused verbatim, so a
  combined run admits each once), plus the plan-boundary events.
  """
  @spec mappings() :: [Mapping.t()]
  def mappings do
    reused = Enum.filter(Brce.ocel_mappings(), &(&1.event in @reused_brce_events))
    reused ++ own_mappings()
  end

  defp own_mappings do
    [
      Mapping.new!(
        event: [:ash_a2a, :command_bus, :preflight],
        activity: "brce.preflight",
        source: __MODULE__,
        objects: fn _m, meta ->
          [
            {"command", meta[:command_id], "command"},
            {"capability", meta[:capability_id], "capability"},
            {"principal", meta[:principal_id], "principal"},
            {"plan", meta[:plan_digest], "plan"},
            {"preflight", meta[:preflight_digest], "preflight"}
          ]
        end,
        attributes: fn _m, meta -> Map.take(meta, [:outcome, :code, :fields]) end
      ),
      Mapping.new!(
        event: [:ash_a2a, :planning, :preflight],
        activity: "plan.preflight",
        source: __MODULE__,
        objects: fn _m, meta ->
          [
            {"plan", meta[:plan_digest], "plan"},
            {"preflight", meta[:preflight_digest], "preflight"}
          ]
        end,
        attributes: fn m, meta ->
          meta |> Map.take([:outcome, :code, :fields]) |> Map.put(:bound_fields, m[:bound_fields])
        end
      ),
      Mapping.new!(
        event: [:ash_a2a, :semantic, :plan_package],
        activity: "plan.package",
        source: __MODULE__,
        objects: fn _m, meta -> [{"plan", meta[:plan_digest], "plan"}] end,
        attributes: fn _m, meta ->
          Map.take(meta, [:outcome, :code, :profile, :planner_identity, :fields])
        end
      ),
      Mapping.new!(
        event: [:ash_a2a, :semantic, :select],
        activity: "plan.select",
        source: __MODULE__,
        objects: fn _m, meta ->
          [
            {"plan", meta[:chosen_digest], "chosen"},
            {"selection", meta[:selection_digest], "selection"}
          ]
        end,
        attributes: fn m, meta ->
          meta
          |> Map.take([:outcome, :code, :standing, :authority, :selector_identity])
          |> Map.put(:candidates, m[:candidates])
        end
      ),
      Mapping.new!(
        event: [:ash_a2a, :semantic, :construct],
        activity: "plan.construct",
        source: __MODULE__,
        objects: fn _m, meta ->
          [
            {"plan", meta[:plan_digest], "plan"},
            {"artifact", meta[:artifact_digest], "artifact"}
          ]
        end,
        attributes: fn _m, meta -> Map.take(meta, [:outcome, :code, :standing, :authority]) end
      )
    ]
  end
end
