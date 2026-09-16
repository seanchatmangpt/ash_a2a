defmodule AshA2A.Semantic.Episode do
  @moduledoc """
  Bounded autonomous episode executor (RFC-SA2A-002 §37 Gate 6, §83 resource
  bounds, §88 B4 planning, §127 bounded concurrency, §132 no blank checks,
  §133 production boundedness).

  An admitted, strict `AshA2A.Semantic.PlanPackage` runs to a lawful terminal
  condition in ONE call -- no caller-by-caller reinterpretation -- while
  consuming an admitted resource envelope:

      completed | quiescent | refused | resource_exhausted | bound_reached

  There is no unbounded path. The executor composes the existing machinery
  rather than re-deriving it:

    * `AshA2A.Semantic.BoundedProduction` -- the control contract. A known
      operation whose termination is "continue reasoning until you believe
      the task is complete" is refused (`:unbounded_production_operation`,
      §133); the stage loop itself is `BoundedProduction.run/3`, so max-steps
      and wall-clock bounds terminate it from outside.
    * `AshA2A.Semantic.Bounds` -- structural ceilings (fan-out, depth,
      parallelism, capabilities) and the execution count; `Bounds.delegate/2`
      is the only way a subtask obtains an envelope (§127).
    * `AshA2A.Semantic.Allocator` -- spend dimensions (model tokens, money,
      external requests, retries, measured wall time) with its no-self-grant
      semantics: a running worker's resource request is `request_increase/2`,
      which always refuses (§132); larger limits only come from a non-model
      issuer through `reallocate/3` -- a new allocation decision that carries
      consumption forward.
    * `AshA2A.CommandBus` -- the sole consequence boundary. Every transition
      is a `AshA2A.Command` authorized for the episode's principal by
      `AshA2A.Authority.Grant`; nothing in the plan, binding or envelope is
      authority.

  ## Envelope (§83: finite, declared, fail closed)

  `issue/2` requires every dimension: `:fan_out`, `:depth`, `:parallelism`,
  `:capabilities`, `:executions`, `:memory_bytes`, `:tokens`,
  `:money_micros`, `:external_requests`, `:retries`, `:wall_time_ms`. No
  default, no `:infinity`. A ceiling above `max_ceiling/0` (2^63-1) is
  refused (`:episode_envelope_ceiling_overflow`) -- a value a heterogeneous
  peer would wrap is not a finite bound. Accounting lives in
  `AshA2A.Semantic.Episode.Ledger`; handles are identity only.

  The effective ceiling for a run is the minimum of the envelope and the
  package's own declared bounds (`max_fan_out`, `max_depth`,
  `max_parallelism`, `resource_envelope`).

  ## Plan binding

  `run/3` binds every `package.action_identities` entry (in order) through
  `opts[:bind]` to a transition:

      %{capability_id: String.t(), input: map(), stage: term(),
        cost: %{tokens: n, money_micros: n, external_requests: n}}

  or a subtask:

      %{kind: :subplan, package: PlanPackage.t(), bind: fun, control: keyword(),
        delegate: keyword(), stage: term()}

  Transitions sharing a `:stage` run in one parallel window (fan-out),
  stages run in order (depth). Every bound capability must be declared by
  the package (`required_capabilities`) and delegated to the envelope. A
  subtask runs as the parent's principal on an envelope delegated from the
  parent's; it may not name a principal or authority.

  ## One stage

    1. `[:episode, :transition, :request]` for each transition (the stimulus
       reached the executor, before any guard).
    2. Depth, fan-out, memory, runtime and execution-count guards
       (`[:episode, :bound]`), then one atomic ledger charge of executions and
       declared costs.
    3. Routes through `AshA2A.CommandBus`, at most `parallelism` in flight.
    4. A refused route terminates the episode (`:refused`); a failed route is
       retried only by charging `:retries` (and `:executions`); a committed
       worker reply carrying `need_more_resources` is a resource-extension
       request, refused by the allocator, and terminates the episode.

  ## Telemetry

  | event                                             | decided                                 |
  |---------------------------------------------------|-----------------------------------------|
  | `[:ash_a2a, :episode, :planning]`                 | projection / planner / package admission|
  | `[:ash_a2a, :episode, :allocation]`               | issue / delegate / extension / reissue  |
  | `[:ash_a2a, :episode, :start]`                    | episode reached the executor            |
  | `[:ash_a2a, :episode, :admission]`                | plan + contract + binding admission     |
  | `[:ash_a2a, :episode, :transition, :request]`     | transition reached a stage              |
  | `[:ash_a2a, :episode, :bound]`                    | one bound decision                      |
  | `[:ash_a2a, :episode, :transition, :start]`       | route admitted into the window          |
  | `[:ash_a2a, :episode, :transition, :stop]`        | route outcome, authority/DO latency     |
  | `[:ash_a2a, :episode, :stop]`                     | terminal outcome                        |
  """

  alias AshA2A.{Command, CommandBus, Identity, Receipt}
  alias AshA2A.Authority.Grant
  alias AshA2A.Planning.HddlSolver

  alias AshA2A.Semantic.{
    Allocator,
    BoundedProduction,
    Bounds,
    IR,
    Ontology,
    PlanningIR,
    PlanPackage,
    PlanProjection
  }

  alias __MODULE__.{Envelope, Ledger}

  @max_ceiling 9_223_372_036_854_775_807
  @budget_dimensions [:tokens, :money_micros, :external_requests, :retries, :wall_time_ms]
  @cost_dimensions [:tokens, :money_micros, :external_requests]
  @delegable_spend [:tokens, :money_micros, :external_requests, :retries]
  @structure [:fan_out, :depth, :parallelism, :capabilities]
  @required_spec @structure ++ [:executions, :memory_bytes] ++ @budget_dimensions

  defmodule Result do
    @moduledoc "Terminal state of one autonomous episode."
    defstruct [
      :episode_id,
      :envelope_id,
      :plan_digest,
      :outcome,
      :code,
      :resource,
      :detail,
      stages_total: 0,
      stages_run: 0,
      committed: 0,
      failed_attempts: 0,
      retries: 0,
      executions_used: 0,
      routes: [],
      extension: nil,
      duration_us: 0,
      memory_peak_bytes: 0
    ]

    @type t :: %__MODULE__{}
  end

  @refusal_codes %{
    episode_envelope_unknown: :refused_bounds,
    episode_envelope_incomplete: :refused_bounds,
    episode_envelope_ceiling_overflow: :refused_bounds,
    episode_envelope_superseded: :refused_bounds,
    episode_envelope_not_delegated: :refused_bounds,
    episode_cost_invalid: :refused_bounds,
    episode_transition_unbound: :refused_plan,
    episode_capability_undeclared: :refused_plan,
    episode_subplan_incomplete: :refused_plan,
    episode_transition_replayed: :refused_identity,
    episode_invalid_options: :refused_structure,
    episode_termination_crashed: :blocked_resource,
    episode_transition_crashed: :blocked_resource
  }

  @doc false
  def __sa2a_refusal_codes__, do: @refusal_codes

  @doc "Largest representable ceiling (signed 64-bit)."
  @spec max_ceiling() :: pos_integer()
  def max_ceiling, do: @max_ceiling

  @doc "Every dimension `issue/2` requires."
  @spec required_dimensions() :: [atom()]
  def required_dimensions, do: @required_spec

  # --- planning (B4) -----------------------------------------------------------

  @doc """
  Plans an episode from admitted semantics with the real `hddl_cli` planner:
  projection (`PlanningIR` + `PlanProjection`) -> planner invocation
  (`HddlSolver.solve/3`) -> strict `PlanPackage` admission. Each phase emits
  `[:ash_a2a, :episode, :planning]` with its own `duration_us`, so planner
  computation is measured apart from authority and DO (§88).

  The package's `action_identities` are the solver's `htn:exec:` policy
  actions, `method_identities` its `htn:decompose:` actions. `opts[:package]`
  supplies the remaining `PlanPackage.from_projection/3` options (bounds,
  capabilities, ...). `opts[:cli_path]`/`opts[:tmp_dir]` go to the solver.
  """
  @spec plan(IR.t(), Ontology.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, map()}
  def plan(%IR{} = ir, %Ontology{} = ontology, domain_text, problem_text, opts \\ [])
      when is_binary(domain_text) and is_binary(problem_text) do
    planning_id = new_id("planning")

    with {:ok, projection} <-
           planning_phase(planning_id, :projection, fn ->
             with {:ok, planning} <- PlanningIR.from_ir(ir, ontology),
                  do: PlanProjection.from_admitted(planning, ontology)
           end),
         {:ok, solved} <-
           planning_phase(planning_id, :planner, fn ->
             HddlSolver.solve(
               domain_text,
               problem_text,
               Keyword.take(opts, [:cli_path, :tmp_dir])
             )
           end),
         {methods, actions} = policy_identities(solved),
         {:ok, package} <-
           planning_phase(planning_id, :package_admission, fn ->
             PlanPackage.from_projection(
               projection,
               "AshA2A.Planning.HddlSolver",
               Keyword.merge(Keyword.get(opts, :package, []),
                 action_identities: actions,
                 method_identities: methods
               )
             )
           end) do
      {:ok,
       %{
         planning_id: planning_id,
         projection: projection,
         package: package,
         planner_output: solved
       }}
    end
  end

  defp planning_phase(planning_id, phase, fun) do
    {us, result} = timed(fun)

    meta =
      Map.merge(
        %{planning_id: planning_id, phase: phase, duration_us: us},
        planning_meta(phase, result)
      )

    emit([:planning], %{duration_us: us}, meta)
    result
  end

  defp planning_meta(_phase, {:error, %{code: code}}), do: %{outcome: :refused, code: code}

  defp planning_meta(:projection, {:ok, %PlanProjection{} = p}),
    do: %{
      outcome: :ok,
      goals: length(p.goals),
      objects: length(p.objects),
      projection_digest: p.projection_digest
    }

  defp planning_meta(:planner, {:ok, solved}) do
    {methods, actions} = policy_identities(solved)
    %{outcome: :ok, planner: "hddl_cli", plan_size: length(actions), methods: length(methods)}
  end

  defp planning_meta(:package_admission, {:ok, %PlanPackage{} = pkg}) do
    envelope = pkg.resource_envelope || %{}

    %{
      outcome: :ok,
      plan_digest: pkg.plan_digest,
      plan_size: length(pkg.action_identities),
      profile: pkg.profile,
      max_fan_out: pkg.max_fan_out,
      max_depth: pkg.max_depth,
      max_parallelism: pkg.max_parallelism,
      max_wall_ms: Map.get(envelope, :max_wall_ms),
      max_memory_bytes: Map.get(envelope, :max_memory_bytes),
      max_invocations: Map.get(envelope, :max_invocations)
    }
  end

  defp planning_meta(_phase, _other), do: %{outcome: :refused}

  defp policy_identities(%{"policy" => policy}) when is_list(policy) do
    actions = policy |> Enum.map(&(&1["action"] || "")) |> Enum.filter(&is_binary/1)

    {Enum.filter(actions, &String.starts_with?(&1, "htn:decompose:")),
     Enum.filter(actions, &String.starts_with?(&1, "htn:exec:"))}
  end

  defp policy_identities(_other), do: {[], []}

  # --- envelopes -----------------------------------------------------------------

  @doc """
  Issues a new envelope from `issuer` (`{:host, _}` or a non-model
  `AshA2A.Authority`; a model issuer is refused by the allocator). Every
  dimension in `required_dimensions/0` is required.
  """
  @spec issue(term(), keyword() | map()) :: {:ok, Envelope.t()} | {:error, map()}
  def issue(issuer, spec) when is_list(spec) or is_map(spec) do
    spec = Map.new(spec)

    result =
      with :ok <- spec_complete(spec),
           :ok <- representable(spec),
           {:ok, bounds} <-
             Bounds.new(
               fan_out: spec.fan_out,
               depth: spec.depth,
               parallelism: spec.parallelism,
               capabilities: spec.capabilities,
               resources: %{executions: spec.executions}
             ),
           :ok <- memory_ceiling(spec.memory_bytes),
           {:ok, budget} <- Allocator.new(Map.take(spec, @budget_dimensions), issued_by: issuer) do
        entry = %{
          id: new_id("envelope"),
          bounds: bounds,
          budget: budget,
          memory_bytes: spec.memory_bytes,
          issued_by: issuer,
          parent_id: nil,
          status: :active,
          executions_limit: spec.executions,
          executions_consumed: 0
        }

        with :ok <- Ledger.register(entry),
             do: {:ok, %Envelope{id: entry.id, issued_by: issuer}}
      end

    emit_allocation(:issue, result, %{issuer: issuer_kind(issuer)})
  end

  @doc """
  RFC-SA2A-002 §127. Delegates a strictly narrower child envelope from
  `parent`, debiting the parent in the ledger. Requested `:executions` and
  spend (`:tokens`, `:money_micros`, `:external_requests`, `:retries`) are
  debited; an omitted amount is ZERO, never a fresh allocation. Structure
  (`:fan_out`, `:depth`, `:parallelism`, `:capabilities`) narrows through
  `Bounds.delegate/2`; `:memory_bytes` and `:wall_time_ms` may not exceed the
  parent's. A request naming `:authority` or `:principal` is refused.
  """
  @spec delegate(Envelope.t(), keyword()) :: {:ok, Envelope.t()} | {:error, map()}
  def delegate(%Envelope{id: parent_id}, request) when is_list(request) do
    child_id = new_id("envelope")

    result =
      with :ok <- no_principal(request),
           :ok <- representable(Map.new(request)) do
        Ledger.transact([parent_id], fn %{^parent_id => parent} ->
          delegate_entry(parent, child_id, request)
        end)
      end

    emit_allocation(:delegate, result, %{
      parent_envelope_id: parent_id,
      carries_authority:
        Keyword.has_key?(request, :authority) or Keyword.has_key?(request, :principal),
      requested_executions: scalar_request(request, :executions),
      requested_parallelism: scalar_request(request, :parallelism)
    })
  end

  defp delegate_entry(parent, child_id, request) do
    executions = Keyword.get(request, :executions, 0)
    issuer = {:host, {:delegated_from, parent.id}}

    with :ok <- active(parent),
         :ok <- Allocator.check_wall_time(parent.budget),
         {:ok, %{child: child_bounds, parent: parent_bounds}} <-
           Bounds.delegate(
             parent.bounds,
             Keyword.take(request, @structure ++ [:authority]) ++
               [resources: %{executions: executions}]
           ),
         {:ok, memory} <- narrow_scalar(request, :memory_bytes, parent.memory_bytes),
         {:ok, wall} <-
           narrow_scalar(request, :wall_time_ms, Allocator.remaining(parent.budget).wall_time_ms),
         {:ok, parent_budget, child_limits} <- debit_spend(parent.budget, request),
         {:ok, child_budget} <-
           Allocator.new(Map.put(child_limits, :wall_time_ms, wall), issued_by: issuer) do
      child = %{
        id: child_id,
        bounds: child_bounds,
        budget: child_budget,
        memory_bytes: memory,
        issued_by: issuer,
        parent_id: parent.id,
        status: :active,
        executions_limit: executions,
        executions_consumed: 0
      }

      {:ok,
       %{
         parent.id => %{parent | bounds: parent_bounds, budget: parent_budget},
         child_id => child
       }, %Envelope{id: child_id, issued_by: issuer, parent_id: parent.id}}
    end
  end

  defp debit_spend(budget, request) do
    Enum.reduce_while(@delegable_spend, {:ok, budget, %{}}, fn dim, {:ok, budget, limits} ->
      case Keyword.get(request, dim, 0) do
        0 ->
          {:cont, {:ok, budget, Map.put(limits, dim, 0)}}

        amount when is_integer(amount) and amount > 0 ->
          case Allocator.allocate(budget, dim, amount) do
            {:ok, budget} -> {:cont, {:ok, budget, Map.put(limits, dim, amount)}}
            {:error, refusal} -> {:halt, {:error, refusal}}
          end

        other ->
          {:halt, {:error, %{code: :bounds_resource_invalid, detail: %{key: dim, value: other}}}}
      end
    end)
  end

  @doc """
  RFC-SA2A-002 §132: `NeedMoreResources ⇏ GrantMoreResources`. A running
  worker's request for more of any dimension is decided by
  `Allocator.request_increase/2`, which has no success clause. The envelope
  is unchanged.
  """
  @spec request_extension(Envelope.t(), term()) :: {:error, map()}
  def request_extension(%Envelope{id: id}, request) do
    result =
      with {:ok, entry} <- Ledger.fetch(id),
           do: Allocator.request_increase(entry.budget, request)

    emit_allocation(:extension, result, %{requested: inspect(request, limit: 20)})
  end

  @doc """
  A NEW allocation decision for `envelope` by a non-model `issuer`
  (`Allocator.reissue/3`): consumption is carried forward, limits may not
  fall below it, and the old envelope is superseded (can no longer be
  spent). `limits` may name `:executions` and any spend dimension; omitted
  dimensions keep their current limit.
  """
  @spec reallocate(Envelope.t(), term(), keyword() | map()) ::
          {:ok, Envelope.t()} | {:error, map()}
  def reallocate(%Envelope{id: id}, issuer, limits) when is_list(limits) or is_map(limits) do
    limits = Map.new(limits)
    new_id = new_id("envelope")

    result =
      with :ok <- representable(limits) do
        Ledger.transact([id], fn %{^id => entry} ->
          reissue_entry(entry, new_id, issuer, limits)
        end)
      end

    emit_allocation(:reissue, result, %{issuer: issuer_kind(issuer), parent_envelope_id: id})
  end

  defp reissue_entry(entry, new_id, issuer, limits) do
    spend = Map.merge(entry.budget.limits, Map.take(limits, @budget_dimensions))
    executions = Map.get(limits, :executions, entry.executions_limit)

    with :ok <- active(entry),
         {:ok, budget} <- Allocator.reissue(entry.budget, issuer, spend),
         :ok <- executions_cover_consumed(executions, entry.executions_consumed) do
      bounds = %{
        entry.bounds
        | resources:
            Map.put(entry.bounds.resources, :executions, executions - entry.executions_consumed)
      }

      next = %{
        entry
        | id: new_id,
          bounds: bounds,
          budget: budget,
          issued_by: issuer,
          parent_id: entry.id,
          executions_limit: executions
      }

      {:ok, %{entry.id => %{entry | status: :superseded}, new_id => next},
       %Envelope{id: new_id, issued_by: issuer, parent_id: entry.id}}
    end
  end

  defp executions_cover_consumed(limit, consumed) when is_integer(limit) and limit >= consumed,
    do: :ok

  defp executions_cover_consumed(limit, consumed),
    do:
      {:error,
       %{code: :reissue_below_consumed, dimensions: %{executions: consumed}, requested: limit}}

  @doc "Ledger view of an envelope (limits, consumption, status)."
  @spec snapshot(Envelope.t() | String.t()) :: {:ok, map()} | {:error, map()}
  def snapshot(%Envelope{id: id}), do: snapshot(id)

  def snapshot(id) when is_binary(id) do
    with {:ok, e} <- Ledger.fetch(id) do
      {:ok,
       %{
         id: e.id,
         status: e.status,
         parent_id: e.parent_id,
         issued_by: e.issued_by,
         fan_out: e.bounds.fan_out,
         depth: e.bounds.depth,
         parallelism: e.bounds.parallelism,
         capabilities: e.bounds.capabilities |> MapSet.to_list() |> Enum.sort(),
         memory_bytes: e.memory_bytes,
         executions: %{
           limit: e.executions_limit,
           consumed: e.executions_consumed,
           remaining: e.bounds.resources.executions
         },
         spend: %{limits: e.budget.limits, consumed: e.budget.consumed}
       }}
    end
  end

  defp spec_complete(spec) do
    case Enum.reject(@required_spec, &Map.has_key?(spec, &1)) do
      [] -> :ok
      missing -> {:error, %{code: :episode_envelope_incomplete, detail: %{missing: missing}}}
    end
  end

  defp representable(spec) do
    overflow =
      spec
      |> Enum.filter(fn {_k, v} -> is_integer(v) and v > @max_ceiling end)
      |> Enum.map(&elem(&1, 0))

    if overflow == [],
      do: :ok,
      else:
        {:error,
         %{
           code: :episode_envelope_ceiling_overflow,
           detail: %{fields: Enum.sort(overflow), max: @max_ceiling}
         }}
  end

  defp memory_ceiling(value) when is_integer(value) and value >= 0, do: :ok

  defp memory_ceiling(value),
    do: {:error, %{code: :bounds_ceiling_invalid, detail: %{field: :memory_bytes, value: value}}}

  defp narrow_scalar(request, key, ceiling) do
    case Keyword.fetch(request, key) do
      :error when is_integer(ceiling) ->
        {:ok, max(ceiling, 0)}

      {:ok, value} when is_integer(value) and value >= 0 and value <= ceiling ->
        {:ok, value}

      {:ok, value} ->
        {:error,
         %{
           code: :bounds_delegation_not_narrowing,
           detail: %{field: key, parent: ceiling, requested: value}
         }}
    end
  end

  defp no_principal(request) do
    if Keyword.has_key?(request, :principal),
      do:
        {:error,
         %{
           code: :bounds_authority_not_delegable,
           detail: inspect(Keyword.get(request, :principal))
         }},
      else: :ok
  end

  defp active(%{status: :active}), do: :ok

  defp active(%{id: id, status: status}),
    do:
      {:error, %{code: :episode_envelope_superseded, detail: %{envelope_id: id, status: status}}}

  # --- run -------------------------------------------------------------------------

  @doc """
  Runs `package` to a lawful terminal condition against `envelope`.

  Required options: `:principal`, `:resource_or_domain`, `:bind`
  (`action_identity -> {:ok, transition} | {:error, reason}`), `:control`
  (`BoundedProduction.contract/2` options: `:termination` -- a real 1-arity
  predicate over the episode view `%{stages_run, committed, pending_stages,
  executions_used}` --, `:max_steps` (stages), `:max_wall_time_ms`).
  Optional: `:parallelism` (requested), `:authority_opts`, `:store`,
  `:store_opts`, `:agent_id`, `:parent` (the envelope id this episode must be
  delegated from), `:episode_id`.

  Returns `{:ok, %Result{}}` for every terminal outcome, refusals included,
  and `{:error, refusal}` only for unusable options.
  """
  @spec run(PlanPackage.t(), Envelope.t(), keyword()) :: {:ok, Result.t()} | {:error, map()}
  def run(%PlanPackage{} = package, %Envelope{} = envelope, opts) when is_list(opts) do
    with {:ok, cfg} <- config(opts) do
      episode_id = Keyword.get_lazy(opts, :episode_id, fn -> new_id("episode") end)

      state = %{
        cfg: cfg,
        package: package,
        episode_id: episode_id,
        envelope: envelope,
        started: System.monotonic_time(:microsecond),
        eff: nil,
        contract: nil,
        pending: [],
        terminal: nil,
        result: %Result{
          episode_id: episode_id,
          envelope_id: envelope.id,
          plan_digest: package.plan_digest
        }
      }

      emit([:start], %{}, %{
        episode_id: episode_id,
        envelope_id: envelope.id,
        parent_envelope_id: cfg.parent,
        plan_digest: package.plan_digest,
        plan_size: length(package.action_identities),
        requested_parallelism: cfg.parallelism
      })

      {:ok, admit_and_execute(state)}
    end
  end

  defp admit_and_execute(state) do
    {us, decision} = timed(fn -> admit(state) end)

    case decision do
      {:ok, state} ->
        emit([:admission], %{duration_us: us}, admission_meta(state, us, :admitted, nil))
        execute(state)

      {:error, state, %{code: code} = refusal} ->
        emit([:admission], %{duration_us: us}, admission_meta(state, us, :refused, code))

        state
        |> put_detail(refusal)
        |> finish(:refused, code, Map.get(refusal, :resource))
    end
  end

  defp admission_meta(state, us, outcome, code) do
    eff = state.eff || %{}

    %{
      episode_id: state.episode_id,
      envelope_id: state.envelope.id,
      plan_digest: state.package.plan_digest,
      outcome: outcome,
      code: code,
      duration_us: us,
      stages: length(state.pending),
      contract_max_steps: state.contract && state.contract.max_steps,
      contract_max_wall_time_ms: state.contract && state.contract.max_wall_time_ms,
      depth_ceiling: eff[:depth],
      fan_out_ceiling: eff[:fan_out],
      parallelism_ceiling: eff[:parallelism],
      executions_ceiling: eff[:executions],
      memory_ceiling: eff[:memory_bytes],
      wall_ceiling_ms: eff[:wall_ms]
    }
  end

  defp admit(state) do
    %{cfg: cfg, package: package, envelope: envelope} = state

    with {:ok, entry} <- Ledger.fetch(envelope.id),
         :ok <- active(entry),
         :ok <- Bounds.fence(entry.bounds),
         :ok <- delegated_from(entry, cfg.parent),
         {:ok, _} <- PlanPackage.verify(package),
         :ok <- PlanPackage.enforce_profile(%{package | profile: :strict}),
         eff = effective(entry, package),
         state = %{state | eff: eff},
         {:ok, contract} <- control_contract(package, cfg.control),
         state = %{state | contract: contract},
         {:ok, stages} <- bind_all(package, cfg.bind),
         state = %{state | pending: stages},
         :ok <- transitions_admissible(stages, package, entry.bounds),
         {:ok, parallelism} <- admit_parallelism(state, cfg.parallelism || eff.parallelism) do
      {:ok,
       %{
         state
         | eff: Map.put(eff, :requested_parallelism, parallelism),
           result: %{state.result | stages_total: length(stages)}
       }}
    else
      {:error, %{code: _} = refusal} -> {:error, state, refusal}
    end
  end

  defp delegated_from(_entry, nil), do: :ok
  defp delegated_from(%{parent_id: parent}, parent), do: :ok

  defp delegated_from(entry, parent),
    do:
      {:error,
       %{
         code: :episode_envelope_not_delegated,
         detail: %{envelope_id: entry.id, parent_id: entry.parent_id, required_parent: parent}
       }}

  defp effective(entry, %PlanPackage{} = pkg) do
    env = pkg.resource_envelope

    %{
      depth: min(entry.bounds.depth, pkg.max_depth),
      fan_out: min(entry.bounds.fan_out, pkg.max_fan_out),
      parallelism: min(entry.bounds.parallelism, pkg.max_parallelism),
      executions: env.max_invocations,
      memory_bytes: min(entry.memory_bytes, env.max_memory_bytes),
      wall_ms: env.max_wall_ms
    }
  end

  defp control_contract(%PlanPackage{plan_digest: digest}, control) do
    case normalize_control(control) do
      {:ok, kw} ->
        BoundedProduction.contract("episode:" <> digest, kw)

      :error ->
        {:error,
         %{
           code: :unbounded_production_operation,
           detail: "control contract must be a keyword list or map of bounded terms",
           termination: control
         }}
    end
  end

  # Alternate encodings of one contract (string keys, maps) are normalized so
  # an unbounded termination cannot slip past the contract check by shape.
  defp normalize_control(control) when is_list(control) do
    if Keyword.keyword?(control), do: normalize_control(Map.new(control)), else: :error
  end

  defp normalize_control(control) when is_map(control) do
    {:ok,
     for key <- [:termination, :max_steps, :max_wall_time_ms] do
       {key, Map.get(control, key, Map.get(control, Atom.to_string(key)))}
     end}
  end

  defp normalize_control(_control), do: :error

  defp bind_all(%PlanPackage{action_identities: actions}, bind) do
    actions
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {action, seq}, {:ok, acc} ->
      case safe_bind(bind, action) do
        {:ok, %{} = spec} ->
          {:cont, {:ok, [transition(spec, action, seq) | acc]}}

        other ->
          {:halt,
           {:error,
            %{
              code: :episode_transition_unbound,
              detail: %{action_identity: action, binding: inspect(other, limit: 10)}
            }}}
      end
    end)
    |> case do
      {:ok, transitions} ->
        stages =
          transitions
          |> Enum.reverse()
          |> Enum.chunk_by(& &1.stage)

        {:ok, stages}

      error ->
        error
    end
  end

  defp safe_bind(bind, action) do
    bind.(action)
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp transition(spec, action, seq) do
    kind = Map.get(spec, :kind, :command)

    %{
      kind: kind,
      seq: seq,
      action_identity: action,
      stage: Map.get(spec, :stage, seq),
      capability_id: Map.get(spec, :capability_id),
      input: Map.get(spec, :input, %{}),
      cost: Map.get(spec, :cost, %{}),
      spec: spec
    }
  end

  defp transitions_admissible(stages, package, bounds) do
    stages
    |> List.flatten()
    |> Enum.reduce_while(:ok, fn t, :ok ->
      case transition_admissible(t, package, bounds) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp transition_admissible(%{kind: :subplan, spec: spec}, _package, _bounds) do
    cond do
      Map.has_key?(spec, :principal) or Map.has_key?(spec, :authority) ->
        {:error,
         %{
           code: :bounds_authority_not_delegable,
           detail: "a subtask runs as the parent's principal"
         }}

      not match?(%PlanPackage{}, Map.get(spec, :package)) or
        not is_function(Map.get(spec, :bind), 1) or
          not Keyword.keyword?(Map.get(spec, :delegate, [])) ->
        {:error,
         %{code: :episode_transition_unbound, detail: "subplan needs :package, :bind, :delegate"}}

      true ->
        :ok
    end
  end

  defp transition_admissible(%{kind: :command} = t, package, bounds) do
    cond do
      not is_binary(t.capability_id) or not is_map(t.input) ->
        {:error, %{code: :episode_transition_unbound, detail: t.action_identity}}

      t.capability_id not in package.required_capabilities ->
        {:error,
         %{
           code: :episode_capability_undeclared,
           detail: %{capability_id: t.capability_id, action_identity: t.action_identity}
         }}

      true ->
        with :ok <- Bounds.admit_capability(bounds, t.capability_id), do: cost_valid(t)
    end
  end

  defp transition_admissible(t, _package, _bounds),
    do: {:error, %{code: :episode_transition_unbound, detail: %{kind: t.kind}}}

  defp cost_valid(%{cost: cost} = t) when is_map(cost) do
    Enum.reduce_while(cost, :ok, fn
      {dim, amount}, :ok when dim in @cost_dimensions and is_integer(amount) and amount >= 0 ->
        {:cont, :ok}

      {dim, _amount}, :ok when dim not in @cost_dimensions ->
        {:halt, {:error, %{code: :bounds_resource_unknown, detail: dim, resource: dim}}}

      {dim, amount}, :ok ->
        {:halt,
         {:error,
          %{
            code: :episode_cost_invalid,
            detail: %{action_identity: t.action_identity, key: dim, value: inspect(amount)},
            resource: dim
          }}}
    end)
  end

  defp cost_valid(t),
    do: {:error, %{code: :episode_cost_invalid, detail: %{action_identity: t.action_identity}}}

  # Effective ceiling = min(envelope, package); a requested parallelism that is
  # not a positive integer at or below it is refused before any transition.
  defp admit_parallelism(state, requested) do
    ceiling = state.eff.parallelism

    if is_integer(requested) and requested >= 1 and requested <= ceiling do
      bound_event(state, 0, :parallelism, requested, ceiling, :admitted, nil)
      {:ok, requested}
    else
      bound_event(
        state,
        0,
        :parallelism,
        requested,
        ceiling,
        :refused,
        :bounds_parallelism_exceeded
      )

      {:error,
       %{
         code: :bounds_parallelism_exceeded,
         detail: %{ceiling: ceiling, requested: requested},
         resource: :parallelism
       }}
    end
  end

  # --- execution ----------------------------------------------------------------------

  defp execute(state) do
    user = state.contract.termination

    loop_contract = %{
      state.contract
      | termination: fn s -> s.terminal != nil or s.pending == [] or user_done?(user, s) end
    }

    case BoundedProduction.run(loop_contract, &stage/1, state) do
      {:ok, :terminated, s, _steps} ->
        cond do
          s.terminal != nil ->
            {outcome, code, resource} = s.terminal
            finish(s, outcome, code, resource)

          s.pending == [] ->
            finish(s, :completed, nil, nil)

          safe_termination(user, s) == :crashed ->
            finish(s, :refused, :episode_termination_crashed, nil)

          true ->
            finish(s, :quiescent, nil, nil)
        end

      {:error, %{code: :bound_reached, bound: bound, state: s}} ->
        finish(s, :bound_reached, :bound_reached, bound)
    end
  end

  defp user_done?(user, s), do: safe_termination(user, s) != false

  defp safe_termination(user, s) do
    case user.(view(s)) do
      true -> true
      _ -> false
    end
  rescue
    _ -> :crashed
  end

  defp view(s) do
    %{
      episode_id: s.episode_id,
      stages_run: s.result.stages_run,
      committed: s.result.committed,
      pending_stages: length(s.pending),
      executions_used: s.result.executions_used
    }
  end

  defp stage(%{pending: [transitions | rest]} = s) do
    index = s.result.stages_run + 1
    s = sample_memory(s)

    for t <- transitions do
      emit([:transition, :request], %{}, %{
        episode_id: s.episode_id,
        envelope_id: s.envelope.id,
        stage: index,
        seq: t.seq,
        kind: t.kind,
        capability_id: t.capability_id,
        action_identity: t.action_identity
      })
    end

    commands = Enum.count(transitions, &(&1.kind == :command))

    with :ok <-
           guard(s, index, :depth, index, s.eff.depth, :bound_reached, :bounds_depth_exceeded),
         :ok <-
           guard(
             s,
             index,
             :fan_out,
             length(transitions),
             s.eff.fan_out,
             :refused,
             :bounds_fan_out_exceeded
           ),
         :ok <- memory_guard(s, index),
         :ok <- runtime_guard(s, index),
         :ok <- executions_guard(s, index, commands),
         :ok <- charge(s, index, executions: commands, cost: sum_costs(transitions)) do
      s = %{s | pending: rest}
      s = update(s, &%{&1 | executions_used: &1.executions_used + commands})
      s = run_transitions(s, index, transitions, 1)
      update(s, &%{&1 | stages_run: index})
    else
      {:terminal, outcome, code, resource} -> %{s | terminal: {outcome, code, resource}}
    end
  end

  defp guard(s, index, resource, requested, ceiling, outcome, code) do
    if requested <= ceiling do
      bound_event(s, index, resource, requested, ceiling, :admitted, nil)
      :ok
    else
      bound_event(s, index, resource, requested, ceiling, :refused, code)
      {:terminal, outcome, code, resource}
    end
  end

  defp memory_guard(s, index) do
    {:memory, bytes} = Process.info(self(), :memory)

    guard(
      s,
      index,
      :memory_bytes,
      bytes,
      s.eff.memory_bytes,
      :resource_exhausted,
      :bounds_resource_exhausted
    )
  end

  defp runtime_guard(s, index) do
    elapsed = div(System.monotonic_time(:microsecond) - s.started, 1000)

    with :ok <-
           guard(
             s,
             index,
             :wall_time_ms,
             elapsed,
             s.eff.wall_ms,
             :resource_exhausted,
             :bounds_resource_exhausted
           ) do
      :ok
    end
  end

  defp executions_guard(s, index, n) do
    guard(
      s,
      index,
      :plan_invocations,
      s.result.executions_used + n,
      s.eff.executions,
      :resource_exhausted,
      :bounds_resource_exhausted
    )
  end

  defp sum_costs(transitions) do
    transitions
    |> Enum.filter(&(&1.kind == :command))
    |> Enum.reduce(%{}, fn t, acc -> Map.merge(acc, t.cost, fn _k, a, b -> a + b end) end)
  end

  # One atomic ledger charge: executions (Bounds.consume) and every positive
  # spend dimension (Allocator.allocate, which also re-measures wall time).
  defp charge(s, index, charges) do
    executions = Keyword.get(charges, :executions, 0)
    spend = Keyword.get(charges, :cost, %{})
    id = s.envelope.id

    result =
      Ledger.transact([id], fn %{^id => e} ->
        with :ok <- active(e),
             :ok <- Allocator.check_wall_time(e.budget),
             {:ok, bounds} <- consume_executions(e.bounds, executions),
             {:ok, budget} <- allocate_spend(e.budget, spend) do
          {:ok,
           %{
             id => %{
               e
               | bounds: bounds,
                 budget: budget,
                 executions_consumed: e.executions_consumed + executions
             }
           }, :charged}
        end
      end)

    case result do
      {:ok, :charged} ->
        bound_event(s, index, :envelope_charge, executions, nil, :admitted, nil)
        :ok

      {:error, %{code: code} = refusal} ->
        resource = refusal_resource(refusal)
        bound_event(s, index, resource, executions, nil, :refused, code)
        {:terminal, :resource_exhausted, code, resource}
    end
  end

  defp consume_executions(bounds, 0), do: {:ok, bounds}
  defp consume_executions(bounds, n), do: Bounds.consume(bounds, :executions, n)

  defp allocate_spend(budget, spend) do
    spend
    |> Enum.sort()
    |> Enum.reduce_while({:ok, budget}, fn
      {_dim, 0}, acc ->
        {:cont, acc}

      {dim, amount}, {:ok, budget} ->
        case Allocator.allocate(budget, dim, amount) do
          {:ok, budget} -> {:cont, {:ok, budget}}
          {:error, refusal} -> {:halt, {:error, refusal}}
        end
    end)
  end

  defp refusal_resource(%{resource: resource}) when not is_nil(resource), do: resource
  defp refusal_resource(%{dimension: dim}), do: dim
  defp refusal_resource(%{detail: %{key: key}}), do: key
  defp refusal_resource(_), do: :envelope

  defp run_transitions(s, index, transitions, attempt) do
    routes = route_window(s, index, transitions, attempt)
    s = Enum.reduce(routes, s, fn r, s -> record_route(s, r) end)

    refused = Enum.filter(routes, &(&1.outcome in [:refused, :uncommitted, :replayed]))
    failed = Enum.filter(routes, &(&1.outcome == :failed))
    requests = Enum.filter(routes, &(&1.resource_request != nil))

    cond do
      refused != [] ->
        [first | _] = refused
        %{s | terminal: {:refused, first.code, nil}}

      requests != [] ->
        extension(s, hd(requests))

      failed != [] ->
        retry(s, index, Enum.map(failed, & &1.transition), attempt)

      true ->
        s
    end
  end

  defp record_route(s, route) do
    update(s, fn r ->
      %{
        r
        | routes: [Map.delete(route, :transition) | r.routes],
          committed: r.committed + if(route.outcome == :committed, do: 1, else: 0),
          failed_attempts: r.failed_attempts + if(route.outcome == :failed, do: 1, else: 0)
      }
    end)
  end

  defp extension(s, route) do
    decision = request_extension(s.envelope, route.resource_request)

    extension = %{
      request: route.resource_request,
      command_id: route.command_id,
      outcome: :refused,
      code: decision |> elem(1) |> Map.get(:code)
    }

    s
    |> update(&%{&1 | extension: extension})
    |> Map.put(:terminal, {:refused, extension.code, :extension})
  end

  defp retry(s, index, transitions, attempt) do
    n = length(transitions)

    with :ok <- runtime_guard(s, index),
         :ok <- executions_guard(s, index, n),
         :ok <- charge(s, index, executions: n, cost: %{retries: n}) do
      s =
        update(s, fn r ->
          %{r | retries: r.retries + n, executions_used: r.executions_used + n}
        end)

      run_transitions(s, index, transitions, attempt + 1)
    else
      {:terminal, outcome, code, resource} -> %{s | terminal: {outcome, code, resource}}
    end
  end

  defp route_window(s, index, transitions, attempt) do
    counter = :counters.new(1, [:write_concurrency])
    parallelism = s.eff.requested_parallelism

    transitions
    |> Task.async_stream(&route(s, index, counter, &1, attempt),
      max_concurrency: parallelism,
      ordered: true,
      timeout: :infinity
    )
    |> Enum.zip(transitions)
    |> Enum.map(fn
      {{:ok, route}, _t} ->
        route

      {{:exit, reason}, t} ->
        %{
          transition: t,
          seq: t.seq,
          stage: index,
          attempt: attempt,
          command_id: command_id(s, index, t, attempt),
          outcome: :refused,
          code: :episode_transition_crashed,
          detail: inspect(reason, limit: 10),
          receipt_id: nil,
          resource_request: nil
        }
    end)
  end

  defp route(s, index, counter, t, attempt) do
    :counters.add(counter, 1, 1)

    try do
      in_flight = :counters.get(counter, 1)
      command_id = command_id(s, index, t, attempt)

      base = %{
        episode_id: s.episode_id,
        envelope_id: s.envelope.id,
        stage: index,
        seq: t.seq,
        attempt: attempt,
        kind: t.kind,
        command_id: command_id,
        capability_id: t.capability_id,
        in_flight: in_flight
      }

      emit([:transition, :start], %{in_flight: in_flight}, base)
      route = do_route(s, t, command_id)

      emit(
        [:transition, :stop],
        %{authority_us: route.authority_us, do_us: route.do_us},
        Map.merge(base, %{
          outcome: route.outcome,
          code: route.code,
          receipt_id: route.receipt_id,
          authority: route.authority,
          authority_us: route.authority_us,
          do_us: route.do_us,
          resource_request: route.resource_request != nil,
          child_episode_id: route[:child_episode_id],
          child_outcome: route[:child_outcome]
        })
      )

      Map.merge(route, %{
        transition: t,
        seq: t.seq,
        stage: index,
        attempt: attempt,
        command_id: command_id,
        in_flight: in_flight
      })
    after
      :counters.sub(counter, 1, 1)
    end
  end

  defp do_route(s, %{kind: :command} = t, command_id) do
    cfg = s.cfg

    {authority_us, authority} =
      timed(fn -> Grant.authorize(cfg.principal, t.capability_id, cfg.authority_opts) end)

    command =
      Command.new(t.capability_id,
        command_id: command_id,
        agent_id: cfg.agent_id,
        principal_id: Identity.principal(cfg.principal),
        authority: authority,
        input: t.input,
        metadata: %{plan_digest: s.package.plan_digest, episode_id: s.episode_id}
      )

    message = A2A.Message.new_user([A2A.Part.Data.new(t.input)])

    {do_us, reply} =
      timed(fn ->
        CommandBus.run(command, message, cfg.resource_or_domain,
          store: cfg.store,
          store_opts: cfg.store_opts,
          plan_digest: s.package.plan_digest
        )
      end)

    {outcome, code, receipt} = classify(reply)

    %{
      outcome: outcome,
      code: code,
      receipt: receipt,
      receipt_id: receipt && identity_value(receipt.receipt_id),
      authority: if(authority, do: :granted, else: :absent),
      authority_us: authority_us,
      do_us: do_us,
      resource_request: if(outcome == :committed, do: resource_request(receipt), else: nil)
    }
  end

  defp do_route(s, %{kind: :subplan, spec: spec}, _command_id) do
    cfg = s.cfg

    {do_us, {outcome, code, child}} =
      timed(fn ->
        with {:ok, child_envelope} <- delegate(s.envelope, Map.get(spec, :delegate, [])),
             {:ok, %Result{} = child} <-
               run(spec.package, child_envelope,
                 principal: cfg.principal,
                 resource_or_domain: cfg.resource_or_domain,
                 bind: spec.bind,
                 control: Map.get(spec, :control),
                 parallelism: Map.get(spec, :parallelism),
                 authority_opts: cfg.authority_opts,
                 store: cfg.store,
                 store_opts: cfg.store_opts,
                 agent_id: cfg.agent_id,
                 parent: s.envelope.id
               ) do
          if child.outcome == :completed,
            do: {:committed, nil, child},
            else: {:refused, child.code || :episode_subplan_incomplete, child}
        else
          {:error, %{code: code}} -> {:refused, code, nil}
        end
      end)

    %{
      outcome: outcome,
      code: code,
      receipt: nil,
      receipt_id: nil,
      authority: :inherited,
      authority_us: 0,
      do_us: do_us,
      resource_request: nil,
      child_episode_id: child && child.episode_id,
      child_outcome: child && child.outcome,
      child: child
    }
  end

  defp classify({:ok, %Receipt{replayed?: true} = r}),
    do: {:replayed, :episode_transition_replayed, r}

  defp classify({:ok, %Receipt{status: :completed} = r}), do: {:committed, nil, r}
  defp classify({:ok, %Receipt{status: status} = r}), do: {:failed, status, r}
  defp classify({:error, %{code: code, receipt: %Receipt{} = r}}), do: {:uncommitted, code, r}
  defp classify({:error, %{code: code}}), do: {:refused, code, nil}
  defp classify(_other), do: {:refused, :episode_transition_crashed, nil}

  # A worker's resource-extension request: a `need_more_resources` map at any
  # depth of the committed reply's data parts (nesting is not a bypass).
  defp resource_request(%Receipt{reply: {:reply, parts}}) when is_list(parts) do
    Enum.find_value(parts, fn
      %A2A.Part.Data{data: data} -> find_request(data)
      _ -> nil
    end)
  end

  defp resource_request(_receipt), do: nil

  defp find_request(%{} = map) do
    case Map.get(map, "need_more_resources", Map.get(map, :need_more_resources)) do
      nil -> map |> Map.values() |> Enum.find_value(&find_request/1)
      request -> request
    end
  end

  defp find_request(list) when is_list(list), do: Enum.find_value(list, &find_request/1)
  defp find_request(_), do: nil

  # --- terminal -------------------------------------------------------------------

  defp finish(s, outcome, code, resource) do
    s = sample_memory(s)
    duration = System.monotonic_time(:microsecond) - s.started
    r = s.result

    emit(
      [:stop],
      %{duration_us: duration, memory_peak_bytes: r.memory_peak_bytes},
      %{
        episode_id: s.episode_id,
        envelope_id: s.envelope.id,
        plan_digest: s.package.plan_digest,
        outcome: outcome,
        code: code,
        resource: resource,
        stages_total: r.stages_total,
        stages_run: r.stages_run,
        committed: r.committed,
        retries: r.retries,
        executions_used: r.executions_used,
        extension: r.extension && r.extension.outcome,
        duration_us: duration,
        memory_peak_bytes: r.memory_peak_bytes
      }
    )

    %{
      r
      | outcome: outcome,
        code: code,
        resource: resource,
        duration_us: duration,
        routes: Enum.reverse(r.routes)
    }
  end

  # --- helpers -----------------------------------------------------------------------

  defp config(opts) do
    with {:ok, principal} <- required(opts, :principal),
         {:ok, resource} <- required(opts, :resource_or_domain),
         {:ok, bind} <- required(opts, :bind),
         true <- is_function(bind, 1) || invalid({:bind, :not_a_function}) do
      {:ok,
       %{
         principal: principal,
         resource_or_domain: resource,
         bind: bind,
         control: Keyword.get(opts, :control),
         parallelism: Keyword.get(opts, :parallelism),
         authority_opts: Keyword.get(opts, :authority_opts, []),
         store: Keyword.get(opts, :store, CommandBus.default_store()),
         store_opts: Keyword.get(opts, :store_opts, []),
         agent_id: Keyword.get(opts, :agent_id, "episode-executor"),
         parent: Keyword.get(opts, :parent)
       }}
    end
  end

  defp required(opts, key) do
    case Keyword.get(opts, key) do
      nil -> invalid({:missing, key})
      value -> {:ok, value}
    end
  end

  defp invalid(detail), do: {:error, %{code: :episode_invalid_options, detail: detail}}

  defp bound_event(s, index, resource, requested, ceiling, outcome, code) do
    meta = %{
      episode_id: s.episode_id,
      envelope_id: s.envelope.id,
      stage: index,
      resource: resource,
      requested: requested,
      ceiling: ceiling,
      outcome: outcome,
      code: code
    }

    emit([:bound], %{}, meta)
  end

  defp emit_allocation(kind, result, extra) do
    {outcome, code, envelope_id} =
      case result do
        {:ok, %Envelope{id: id}} -> {:admitted, nil, id}
        {:error, %{code: code}} -> {:refused, code, nil}
      end

    emit(
      [:allocation],
      %{},
      Map.merge(extra, %{kind: kind, outcome: outcome, code: code, envelope_id: envelope_id})
    )

    result
  end

  defp issuer_kind({kind, _}) when is_atom(kind), do: kind
  defp issuer_kind(%AshA2A.Authority{source: source}), do: "authority:#{source}"
  defp issuer_kind(_other), do: :invalid

  defp scalar_request(request, key) do
    case Keyword.get(request, key) do
      value when is_integer(value) -> value
      nil -> nil
      other -> inspect(other, limit: 5)
    end
  end

  defp command_id(s, index, t, attempt),
    do: "#{s.episode_id}:s#{index}:t#{t.seq}:a#{attempt}"

  defp put_detail(s, refusal), do: update(s, &%{&1 | detail: Map.get(refusal, :detail)})

  defp update(s, fun), do: %{s | result: fun.(s.result)}

  defp sample_memory(s) do
    {:memory, bytes} = Process.info(self(), :memory)
    update(s, &%{&1 | memory_peak_bytes: max(&1.memory_peak_bytes, bytes)})
  end

  defp emit(suffix, measurements, metadata),
    do: :telemetry.execute([:ash_a2a, :episode | suffix], measurements, metadata)

  defp timed(fun) do
    started = System.monotonic_time(:microsecond)
    value = fun.()
    {System.monotonic_time(:microsecond) - started, value}
  end

  defp identity_value(%Identity{value: value}), do: value
  defp identity_value(value), do: value

  defp new_id(prefix),
    do: prefix <> "-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
end
