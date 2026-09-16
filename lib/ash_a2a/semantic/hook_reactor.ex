defmodule AshA2A.Semantic.HookReactor do
  @moduledoc """
  Minimal real, bounded Knowledge Hook reactor (RFC-SA2A-002 §60-§63, §87,
  §90; RFC-SA2A-001 §34 bounds and knowledge hooks).

      Hook ≠ DO        HookOutput ⇒ SemanticIntent        SemanticIntent ⇏ Authority

  ## One reactive episode (`run/2`)

    1. The delta is parsed fail-closed and given its canonical identity
       (`AshA2A.Semantic.HookReactor.Engine.canonical_delta/1`).
    2. The admitted bounds (`AshA2A.Semantic.Bounds`) are fenced and the
       requested parallelism admitted against them.
    3. For each generation, every hook in `:hooks` is evaluated against every
       delta in the frontier. A hook whose current digest is not in the
       `:admission` set is refused (`:hook_not_admitted`) *without* being
       evaluated -- it cannot fire with production standing (§61). Admitted
       hook conditions are decided by the real GraphLaw engine.
    4. If anything fired and the generation exceeds `bounds.depth`, the
       episode terminates with `:bounds_depth_exceeded` before any intent is
       constructed.
    5. Every fired hook yields exactly one candidate
       `AshA2A.Semantic.HookReactor.Intent` (no authority). If the intents one
       delta produced exceed `bounds.fan_out`, the episode terminates with
       `:bounds_fan_out_exceeded` before any is routed.
    6. Intents are routed, at most `parallelism` at a time, as
       `AshA2A.Command`s through `AshA2A.CommandBus` -- the sole consequence
       boundary. Authority for each is decided by
       `AshA2A.Authority.Grant.authorize/3` for the episode's `:principal`;
       nothing the hook carries is authority (meta-admission refuses a hook
       whose template even mentions one).
    7. Only a fresh, committed, completed receipt produces a resulting delta
       (via `:project`); refused, failed, uncommitted and replayed routes feed
       nothing back. Those deltas form the next generation's frontier.
    8. The episode ends at quiescence (nothing fired / nothing fed back) or
       at a typed refusal. There is no unbounded path.

  ## Telemetry (the boundary's own evidence)

  | event                                              | decided                                   |
  |----------------------------------------------------|-------------------------------------------|
  | `[:ash_a2a, :hook_reactor, :hook, :admission]`     | hook meta-admission `:admitted|:refused`  |
  | `[:ash_a2a, :hook_reactor, :cascade, :start]`      | episode start (delta identity, bounds)    |
  | `[:ash_a2a, :hook_reactor, :cascade, :bound]`      | depth / fan-out / parallelism decision    |
  | `[:ash_a2a, :hook_reactor, :hook, :evaluate]`      | `:fired|:not_fired|:refused` per hook     |
  | `[:ash_a2a, :hook_reactor, :intent, :constructed]` | candidate intent built                    |
  | `[:ash_a2a, :hook_reactor, :intent, :idempotency]` | receipt-store lookup `:new|:seen`         |
  | `[:ash_a2a, :hook_reactor, :intent, :route_start]` | route admitted into the parallel window   |
  | `[:ash_a2a, :hook_reactor, :intent, :routed]`      | CommandBus outcome for the intent         |
  | `[:ash_a2a, :hook_reactor, :cascade, :stop]`       | terminal outcome                          |

  Every event carries `:cascade_id`; durations are in the `:duration_us`
  measurement.
  """

  alias AshA2A.{Command, CommandBus, Identity, Receipt}
  alias AshA2A.Authority.Grant
  alias AshA2A.Semantic.Bounds
  alias AshA2A.Semantic.HookReactor.{Engine, Hook, Intent}

  defmodule Admission do
    @moduledoc """
    The admitted hook set: the digests `AshA2A.Semantic.HookReactor.admit/2`
    recorded. Standing is membership of a hook's *current* digest, never a
    field the hook carries.
    """
    defstruct digests: MapSet.new()

    @type t :: %__MODULE__{digests: MapSet.t(String.t())}

    @spec admitted?(t(), AshA2A.Semantic.HookReactor.Hook.t()) :: boolean()
    def admitted?(%__MODULE__{digests: digests}, %AshA2A.Semantic.HookReactor.Hook{} = hook),
      do: MapSet.member?(digests, AshA2A.Semantic.HookReactor.Hook.digest(hook))

    def admitted?(_admission, _hook), do: false
  end

  defmodule Result do
    @moduledoc "Terminal state of one reactive episode."
    defstruct [
      :cascade_id,
      :outcome,
      :code,
      :delta_digest,
      :delta_size,
      generations: 0,
      depth_reached: 0,
      evaluations: [],
      intents: [],
      routes: [],
      bound_decisions: [],
      duration_us: 0,
      memory_peak_bytes: 0
    ]

    @type t :: %__MODULE__{}
  end

  @refusal_codes %{
    hook_identity_invalid: :refused_identity,
    hook_condition_identity_mismatch: :refused_identity,
    hook_provenance_missing: :refused_provenance,
    hook_condition_invalid: :refused_structure,
    hook_intent_invalid: :refused_structure,
    hook_witness_invalid: :refused_structure,
    hook_delta_unparseable: :refused_structure,
    hook_projection_invalid: :refused_structure,
    hook_reactor_invalid_options: :refused_structure,
    hook_condition_witness_failed: :refused_rule,
    hook_authority_forbidden: :refused_authority,
    hook_not_admitted: :refused_meta_rigor,
    hook_engine_unavailable: :blocked_resource,
    hook_route_crashed: :blocked_resource,
    hook_engine_unexpected: :blocked_unknown
  }

  @doc false
  def __sa2a_refusal_codes__, do: @refusal_codes

  # --- meta-admission -------------------------------------------------------

  @doc """
  Meta-admits `hooks` (§61): structural identity/provenance/condition checks
  (`Hook.validate/1`) and then a real-engine witness check -- the trigger (and
  guard) must match the hook's declared witness and must NOT match the empty
  graph, so a malformed (silently never-matching) or self-satisfying
  condition cannot be admitted.

  Options: `:runtime` (required, `Engine.open/1`), `:admission` (an existing
  set to extend). Returns the admitted set and the refusals.
  """
  @spec admit([Hook.t()], keyword()) :: %{admission: Admission.t(), refused: [map()]}
  def admit(hooks, opts) when is_list(hooks) do
    runtime = Keyword.fetch!(opts, :runtime)
    initial = %{admission: Keyword.get(opts, :admission, %Admission{}), refused: []}

    Enum.reduce(hooks, initial, fn hook, acc ->
      {us, decision} =
        timed(fn ->
          with :ok <- Hook.validate(hook), do: witness_check(runtime, hook)
        end)

      meta = %{
        hook_id: hook_field(hook, :id),
        revision: hook_field(hook, :revision),
        condition_digest: hook_field(hook, :condition_digest)
      }

      case decision do
        :ok ->
          emit([:hook, :admission], %{duration_us: us}, Map.put(meta, :outcome, :admitted))
          digests = MapSet.put(acc.admission.digests, Hook.digest(hook))
          %{acc | admission: %Admission{digests: digests}}

        {:error, %{code: code} = refusal} ->
          emit(
            [:hook, :admission],
            %{duration_us: us},
            Map.merge(meta, %{outcome: :refused, code: code})
          )

          %{acc | refused: acc.refused ++ [Map.put(refusal, :hook_id, meta.hook_id)]}
      end
    end)
  end

  defp witness_check(runtime, %Hook{} = hook) do
    with {:ok, witness} <- Engine.canonical_delta(hook.witness),
         :ok <- condition_witness(runtime, :trigger, hook.trigger, witness.ntriples) do
      case hook.guard do
        nil -> :ok
        guard -> condition_witness(runtime, :guard, guard, witness.ntriples)
      end
    end
  end

  defp condition_witness(runtime, role, condition, witness_nt) do
    with {:ok, on_witness} <- Engine.matches?(runtime, witness_nt, condition),
         {:ok, on_empty} <- Engine.matches?(runtime, "", condition) do
      cond do
        on_witness != true ->
          {:error,
           %{
             code: :hook_condition_witness_failed,
             detail: "#{role} does not match its declared witness (malformed or unsatisfiable)"
           }}

        on_empty != false ->
          {:error,
           %{
             code: :hook_condition_witness_failed,
             detail: "#{role} matches the empty graph (self-satisfying condition)"
           }}

        true ->
          :ok
      end
    end
  end

  defp hook_field(%Hook{} = hook, field), do: Map.get(hook, field)
  defp hook_field(_other, _field), do: nil

  # --- episode --------------------------------------------------------------

  @doc """
  Runs one bounded reactive episode over the Turtle `delta`.

  Required options: `:runtime`, `:bounds` (`%AshA2A.Semantic.Bounds{}`),
  `:resource_or_domain`, `:principal` (the verified identity the reflex acts
  for). Optional: `:hooks`, `:admission`, `:base` (Turtle context for
  guards), `:parallelism` (requested; default `bounds.parallelism`),
  `:authority_opts` (for `Grant.authorize/3`), `:store`, `:store_opts`,
  `:agent_id`, `:project` (`(Intent.t(), Receipt.t()) -> {:ok, turtle} |
  :none`), `:cascade_id`.

  Returns `{:ok, %Result{}}` for every terminal outcome (quiescence and typed
  refusals alike) and `{:error, refusal}` only for unusable options.
  """
  @spec run(String.t(), keyword()) :: {:ok, Result.t()} | {:error, map()}
  def run(delta, opts) when is_list(opts) do
    with {:ok, cfg} <- config(opts) do
      cascade_id = Keyword.get_lazy(opts, :cascade_id, &new_cascade_id/0)

      state = %{
        cfg: cfg,
        cascade_id: cascade_id,
        started: System.monotonic_time(:microsecond),
        result: %Result{cascade_id: cascade_id}
      }

      {:ok, start(state, delta)}
    end
  end

  defp start(state, delta_text) do
    cfg = state.cfg

    parsed =
      with {:ok, base} <- Engine.canonical_delta(cfg.base),
           {:ok, delta} <- Engine.canonical_delta(delta_text),
           do: {:ok, base, delta}

    delta_meta =
      case parsed do
        {:ok, _base, delta} -> %{delta_digest: delta.digest, delta_size: delta.size}
        _ -> %{delta_digest: nil, delta_size: 0}
      end

    emit(
      [:cascade, :start],
      %{delta_size: delta_meta.delta_size},
      Map.merge(delta_meta, %{
        cascade_id: state.cascade_id,
        depth_ceiling: cfg.bounds.depth,
        fan_out_ceiling: cfg.bounds.fan_out,
        parallelism_ceiling: cfg.bounds.parallelism,
        requested_parallelism: cfg.parallelism,
        hooks: length(cfg.hooks)
      })
    )

    state = update_result(state, &%{&1 | delta_digest: delta_meta.delta_digest})
    state = update_result(state, &%{&1 | delta_size: delta_meta.delta_size})

    with {:ok, base, delta} <- parsed,
         {:ok, state} <- admit_parallelism(state) do
      graph = RDF.Graph.add(base.graph, RDF.Graph.triples(delta.graph))
      generation(state, 1, [delta], graph)
    else
      {:error, %{code: code}} -> finish(state, :refused, code)
      {:refused, state, code} -> finish(state, :refused, code)
    end
  end

  defp admit_parallelism(state) do
    %{bounds: bounds, parallelism: requested} = state.cfg

    decision =
      with :ok <- Bounds.fence(bounds),
           :ok <- positive(requested),
           do: Bounds.admit_parallelism(bounds, requested)

    case decision do
      :ok ->
        {:ok, bound(state, :parallelism, 0, requested, bounds.parallelism, :admitted, nil)}

      {:error, %{code: code}} ->
        {:refused, bound(state, :parallelism, 0, requested, bounds.parallelism, :refused, code),
         code}
    end
  end

  defp positive(n) when is_integer(n) and n >= 1, do: :ok
  defp positive(n), do: {:error, %{code: :bounds_parallelism_exceeded, detail: n}}

  defp generation(state, generation, frontier, graph) do
    state = sample_memory(state)
    state = update_result(state, &%{&1 | generations: generation})
    post_state = RDF.NTriples.write_string!(graph)

    case evaluate_frontier(state, generation, frontier, post_state) do
      {:error, state, code} ->
        finish(state, :refused, code)

      {:ok, state, []} ->
        finish(state, :quiescent, nil)

      {:ok, state, fired} ->
        depth = state.cfg.bounds.depth

        if generation > depth do
          state =
            bound(state, :depth, generation, generation, depth, :refused, :bounds_depth_exceeded)

          finish(state, :refused, :bounds_depth_exceeded)
        else
          state = bound(state, :depth, generation, generation, depth, :admitted, nil)
          {state, intents} = construct(state, generation, fired)

          case admit_fan_out(state, generation, intents) do
            {:refused, state, code} ->
              finish(state, :refused, code)

            {:ok, state} ->
              {state, routes} = route_all(state, intents)
              {state, next} = feedback(state, routes)

              state =
                if Enum.any?(routes, &(&1.outcome == :committed)),
                  do: update_result(state, &%{&1 | depth_reached: generation}),
                  else: state

              case next do
                [] ->
                  finish(state, :quiescent, nil)

                deltas ->
                  graph =
                    Enum.reduce(deltas, graph, &RDF.Graph.add(&2, RDF.Graph.triples(&1.graph)))

                  generation(state, generation + 1, deltas, graph)
              end
          end
        end
    end
  end

  # --- evaluation -------------------------------------------------------------

  defp evaluate_frontier(state, generation, frontier, post_state) do
    hooks =
      state.cfg.hooks
      |> Enum.map(fn hook -> {hook, Hook.digest(hook)} end)
      |> Enum.uniq_by(&elem(&1, 1))
      |> Enum.sort_by(fn {hook, digest} -> {hook.id, digest} end)

    frontier = frontier |> Enum.uniq_by(& &1.digest) |> Enum.sort_by(& &1.digest)

    pairs = for delta <- frontier, {hook, digest} <- hooks, do: {delta, hook, digest}

    Enum.reduce_while(pairs, {:ok, state, []}, fn {delta, hook, digest}, {:ok, state, fired} ->
      case evaluate(state, generation, delta, hook, digest, post_state) do
        {:fired, state} -> {:cont, {:ok, state, fired ++ [{delta, hook, digest}]}}
        {:not_fired, state} -> {:cont, {:ok, state, fired}}
        {:error, state, code} -> {:halt, {:error, state, code}}
      end
    end)
  end

  defp evaluate(state, generation, delta, hook, digest, post_state) do
    meta = %{
      cascade_id: state.cascade_id,
      generation: generation,
      hook_id: hook.id,
      hook_revision: hook.revision,
      delta_digest: delta.digest
    }

    if MapSet.member?(state.cfg.admission.digests, digest) do
      {us, decision} =
        timed(fn ->
          with {:ok, trigger} <- Engine.matches?(state.cfg.runtime, delta.ntriples, hook.trigger),
               {:ok, guard} <- guard(state.cfg.runtime, trigger, hook.guard, post_state),
               do: {:ok, trigger, guard}
        end)

      case decision do
        {:ok, trigger, guard} ->
          outcome = if trigger and guard in [true, :none], do: :fired, else: :not_fired
          meta = Map.merge(meta, %{outcome: outcome, trigger: trigger, guard: guard})
          emit([:hook, :evaluate], %{duration_us: us}, meta)
          {outcome, record(state, :evaluations, Map.put(meta, :duration_us, us))}

        {:error, %{code: code}} ->
          meta = Map.merge(meta, %{outcome: :refused, code: code})
          emit([:hook, :evaluate], %{duration_us: us}, meta)
          {:error, record(state, :evaluations, meta), code}
      end
    else
      meta = Map.merge(meta, %{outcome: :refused, code: :hook_not_admitted})
      emit([:hook, :evaluate], %{duration_us: 0}, meta)
      {:not_fired, record(state, :evaluations, meta)}
    end
  end

  defp guard(_runtime, _trigger, nil, _post_state), do: {:ok, :none}
  defp guard(_runtime, false, _guard, _post_state), do: {:ok, :not_evaluated}
  defp guard(runtime, true, guard, post_state), do: Engine.matches?(runtime, post_state, guard)

  # --- intents ----------------------------------------------------------------

  defp construct(state, generation, fired) do
    {state, intents} =
      Enum.reduce(fired, {state, []}, fn {delta, hook, digest}, {state, acc} ->
        {us, intent} = timed(fn -> Intent.build(hook, digest, delta.digest, generation) end)

        emit([:intent, :constructed], %{duration_us: us}, %{
          cascade_id: state.cascade_id,
          generation: generation,
          hook_id: hook.id,
          delta_digest: delta.digest,
          intent_id: intent.intent_id,
          command_id: Intent.command_id(intent),
          capability_id: intent.capability_id,
          standing: intent.standing,
          authority: :none
        })

        {record(state, :intents, intent), [intent | acc]}
      end)

    {state, intents |> Enum.reverse() |> Enum.uniq_by(& &1.intent_id)}
  end

  defp admit_fan_out(state, generation, intents) do
    bounds = state.cfg.bounds

    intents
    |> Enum.group_by(& &1.delta_digest)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, state}, fn {_digest, group}, {:ok, state} ->
      requested = length(group)

      case Bounds.admit_fan_out(bounds, requested) do
        :ok ->
          {:cont,
           {:ok, bound(state, :fan_out, generation, requested, bounds.fan_out, :admitted, nil)}}

        {:error, %{code: code}} ->
          state = bound(state, :fan_out, generation, requested, bounds.fan_out, :refused, code)
          {:halt, {:refused, state, code}}
      end
    end)
  end

  # --- routing ----------------------------------------------------------------

  defp route_all(state, intents) do
    counter = :counters.new(1, [:write_concurrency])
    intents = Enum.sort_by(intents, & &1.intent_id)
    cfg = state.cfg
    cascade_id = state.cascade_id

    routes =
      intents
      |> Task.async_stream(&route(cfg, cascade_id, counter, &1),
        max_concurrency: cfg.parallelism,
        ordered: true,
        timeout: :infinity
      )
      |> Enum.zip(intents)
      |> Enum.map(fn
        {{:ok, route}, _intent} ->
          route

        {{:exit, reason}, intent} ->
          %{
            intent: intent,
            command_id: Intent.command_id(intent),
            outcome: :failed,
            code: :hook_route_crashed,
            detail: inspect(reason),
            receipt: nil
          }
      end)

    {Enum.reduce(routes, state, &record(&2, :routes, &1)), routes}
  end

  defp route(cfg, cascade_id, counter, %Intent{} = intent) do
    command_id = Intent.command_id(intent)

    base_meta = %{
      cascade_id: cascade_id,
      generation: intent.generation,
      intent_id: intent.intent_id,
      command_id: command_id,
      capability_id: intent.capability_id
    }

    {check_us, seen} = timed(fn -> idempotency(cfg, command_id) end)
    emit([:intent, :idempotency], %{duration_us: check_us}, Map.put(base_meta, :outcome, seen))

    :counters.add(counter, 1, 1)

    try do
      in_flight = :counters.get(counter, 1)

      emit(
        [:intent, :route_start],
        %{in_flight: in_flight},
        Map.put(base_meta, :in_flight, in_flight)
      )

      {us, {authority, reply}} =
        timed(fn ->
          authority = Grant.authorize(cfg.principal, intent.capability_id, cfg.authority_opts)

          command =
            Command.new(intent.capability_id,
              command_id: command_id,
              agent_id: cfg.agent_id,
              principal_id: Identity.principal(cfg.principal),
              authority: authority,
              input: intent.input
            )

          message = A2A.Message.new_user([A2A.Part.Data.new(intent.input)])

          {authority,
           CommandBus.run(command, message, cfg.resource_or_domain,
             store: cfg.store,
             store_opts: cfg.store_opts
           )}
        end)

      {outcome, code, receipt} = classify(reply)

      emit(
        [:intent, :routed],
        %{duration_us: us},
        Map.merge(base_meta, %{
          outcome: outcome,
          code: code,
          authority: if(authority, do: :granted, else: :absent),
          receipt_id: receipt && identity_value(receipt.receipt_id),
          idempotency: seen,
          in_flight: in_flight
        })
      )

      %{
        intent: intent,
        command_id: command_id,
        outcome: outcome,
        code: code,
        receipt: receipt,
        idempotency: seen,
        idempotency_check_us: check_us,
        route_us: us,
        in_flight: in_flight
      }
    after
      :counters.sub(counter, 1, 1)
    end
  end

  defp idempotency(cfg, command_id) do
    case cfg.store.fetch(Identity.command(command_id), cfg.store_opts) do
      {:ok, _receipt} -> :seen
      _ -> :new
    end
  rescue
    _ -> :unavailable
  catch
    :exit, _ -> :unavailable
  end

  defp classify({:ok, %Receipt{replayed?: true} = receipt}), do: {:replayed, nil, receipt}
  defp classify({:ok, %Receipt{status: :completed} = receipt}), do: {:committed, nil, receipt}
  defp classify({:ok, %Receipt{status: status} = receipt}), do: {:failed, status, receipt}

  defp classify({:error, %{code: code, receipt: %Receipt{} = receipt}}),
    do: {:uncommitted, code, receipt}

  defp classify({:error, %{code: code}}), do: {:refused, code, nil}
  defp classify(_other), do: {:refused, :hook_route_crashed, nil}

  # --- feedback ---------------------------------------------------------------

  defp feedback(state, routes) do
    case state.cfg.project do
      nil ->
        {state, []}

      project ->
        deltas =
          routes
          |> Enum.filter(&(&1.outcome == :committed))
          |> Enum.sort_by(& &1.intent.intent_id)
          |> Enum.flat_map(fn route ->
            with {:ok, turtle} <- safe_project(project, route.intent, route.receipt),
                 {:ok, delta} <- Engine.canonical_delta(turtle) do
              [delta]
            else
              _ -> []
            end
          end)
          |> Enum.uniq_by(& &1.digest)

        {state, deltas}
    end
  end

  defp safe_project(project, intent, receipt) do
    case project.(intent, receipt) do
      {:ok, turtle} when is_binary(turtle) -> {:ok, turtle}
      _ -> :none
    end
  rescue
    _ -> :none
  end

  # --- terminal ---------------------------------------------------------------

  defp finish(state, outcome, code) do
    state = sample_memory(state)
    duration = System.monotonic_time(:microsecond) - state.started
    r = state.result
    committed = Enum.count(r.routes, &(&1.outcome == :committed))

    emit(
      [:cascade, :stop],
      %{duration_us: duration, memory_peak_bytes: r.memory_peak_bytes},
      %{
        cascade_id: state.cascade_id,
        outcome: outcome,
        code: code,
        generations: r.generations,
        depth_reached: r.depth_reached,
        intents: length(r.intents),
        receipts: committed,
        duration_us: duration,
        memory_peak_bytes: r.memory_peak_bytes
      }
    )

    %{
      r
      | outcome: outcome,
        code: code,
        duration_us: duration,
        evaluations: Enum.reverse(r.evaluations),
        intents: Enum.reverse(r.intents),
        routes: Enum.reverse(r.routes),
        bound_decisions: Enum.reverse(r.bound_decisions)
    }
  end

  # --- helpers ----------------------------------------------------------------

  defp bound(state, bound, generation, requested, ceiling, outcome, code) do
    meta = %{
      cascade_id: state.cascade_id,
      bound: bound,
      generation: generation,
      requested: requested,
      ceiling: ceiling,
      outcome: outcome,
      code: code
    }

    emit([:cascade, :bound], %{requested: requested, ceiling: ceiling}, meta)
    record(state, :bound_decisions, meta)
  end

  defp record(state, key, value),
    do: update_result(state, &Map.update!(&1, key, fn list -> [value | list] end))

  defp update_result(state, fun), do: %{state | result: fun.(state.result)}

  defp sample_memory(state) do
    {:memory, bytes} = Process.info(self(), :memory)
    update_result(state, &%{&1 | memory_peak_bytes: max(&1.memory_peak_bytes, bytes)})
  end

  defp config(opts) do
    with {:ok, runtime} <- required(opts, :runtime),
         {:ok, %Bounds{} = bounds} <- required(opts, :bounds),
         {:ok, resource} <- required(opts, :resource_or_domain),
         {:ok, principal} <- required(opts, :principal) do
      {:ok,
       %{
         runtime: runtime,
         bounds: bounds,
         resource_or_domain: resource,
         principal: principal,
         hooks: Keyword.get(opts, :hooks, []),
         admission: Keyword.get(opts, :admission, %Admission{}),
         base: Keyword.get(opts, :base, ""),
         parallelism: Keyword.get(opts, :parallelism, bounds.parallelism),
         authority_opts: Keyword.get(opts, :authority_opts, []),
         store: Keyword.get(opts, :store, CommandBus.default_store()),
         store_opts: Keyword.get(opts, :store_opts, []),
         agent_id: Keyword.get(opts, :agent_id, "hook-reactor"),
         project: Keyword.get(opts, :project)
       }}
    else
      {:ok, other} ->
        {:error, %{code: :hook_reactor_invalid_options, detail: {:bounds, inspect(other)}}}

      {:error, _} = error ->
        error
    end
  end

  defp required(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:error, %{code: :hook_reactor_invalid_options, detail: {:missing, key}}}
      value -> {:ok, value}
    end
  end

  defp emit(suffix, measurements, metadata),
    do: :telemetry.execute([:ash_a2a, :hook_reactor | suffix], measurements, metadata)

  defp timed(fun) do
    started = System.monotonic_time(:microsecond)
    value = fun.()
    {System.monotonic_time(:microsecond) - started, value}
  end

  defp identity_value(%Identity{value: value}), do: value
  defp identity_value(value), do: value

  defp new_cascade_id,
    do: "cascade-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
end
