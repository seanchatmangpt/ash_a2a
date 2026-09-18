defmodule AshA2A.Chicago.Bench.B3HookReflex do
  @moduledoc """
  RFC-SA2A-002 §87 benchmark `SA2A-B3` -- Knowledge Hook reflex latency.

  Drives the real `AshA2A.Semantic.HookReactor.run/2` reflex path -- the same
  production boundary `AshA2A.Chicago.Courts.KnowledgeHooks` (`SA2A-HOOK`)
  qualifies -- through the real praxis-graphlaw wasm engine
  (`AshA2A.Semantic.HookReactor.Engine`), the real `AshA2A.CommandBus`, a real
  `AshA2A.ReceiptStore.Memory`, a real `AshA2A.Authority.Broker.InMemory` and
  the real ETS-backed `AshA2A.Chicago.Fixtures.HooksCascade.Signal` resource.
  Hooks, deltas, bounds and the environment are built with the SAME fixture
  module the court uses (`AshA2A.Chicago.Fixtures.HooksCascade`, aliased `F`
  below) -- no invented fixture.

  §87 asks for `delta size`, `hooks evaluated`, `hooks fired`, `intent count`,
  `hook-evaluation latency`, `intent-construction latency` and
  `idempotency-check latency`, over four required cases:

    * `no_match_control` -- delta matches no hook trigger
    * `single_match` -- one hook fires from one delta
    * `multi_match_within_bound` -- two hooks fire from one delta, exactly at
      the admitted fan-out ceiling (the bound is checked as a real invariant,
      not merely exercised)
    * `replay_same_delta` -- the byte-identical delta delivered twice to the
      same admission, reporting the idempotency-check latency on the `:new`
      and `:seen` paths separately (RFC-SA2A-002 §62 identity/replay)

  ## Scope boundary (what B3 deliberately does NOT measure)

  Every case runs with `project: false`: one generation, no cascading
  feedback. Cascade depth / fan-out-across-generations / quiescence-under-load
  is `SA2A-B6`'s scope (RFC §90), not B3's. Hook meta-admission
  (`HookReactor.admit/2`) is real setup run BEFORE the timer starts and
  excluded from every timed region, the same setup/timed-region split
  `AshA2A.Chicago.Bench.B5Authority` uses for grant issuance -- admission
  latency is `SA2A-B1`-adjacent, not a B3 reflex measure. Authority decision
  and CommandBus/BRCE latency are `SA2A-B5`'s scope (RFC §89); B3 only times
  the `hook_reactor` boundary's own telemetry.

  ## Per-event latency (own collector, not `AshA2A.Chicago.Bench.Timeline`)

  `hook.evaluate`, `intent.constructed` and `intent.idempotency` can each fire
  MORE THAN ONCE per episode (once per hook, or per fired hook) --
  `AshA2A.Chicago.Bench.Timeline`'s `first/2`/`gap/2` model (built for B1/B5's
  exactly-one-occurrence-per-stage episodes) cannot disambiguate repeats by
  observer-side arrival gaps alone. This module attaches its own
  `:telemetry.attach_many/4` collector (same `send/2`-to-self shape as
  `Timeline`) that keeps BOTH the measurements map (`:duration_us`, the real
  wall time `AshA2A.Semantic.HookReactor` itself measured internally) and the
  full metadata map, and sums/reads `:duration_us` directly per event kind --
  precise regardless of how many hooks fire in one episode, and never
  perturbing or detaching from the SUT path (mirrors `Timeline`'s own
  never-raise contract).

  ## Counts alongside microsecond phases

  `hooks_evaluated`, `hooks_fired`, `intent_count` and `delta_size` are
  reported as plain integers inside the SAME per-sample `phases` map as the
  microsecond latencies (`hook_evaluation_us`, etc.) -- the identical
  convention `AshA2A.Chicago.Bench.B1Admission` already uses to carry derived,
  non-raw-stage integers (`finalize`, `total_admission`) in its own
  `phases`/`stage_latency_us`. Doing this reuses
  `AshA2A.Chicago.Bench.measure/2`'s own `by_case`/distribution machinery for
  free (real code already exercised by B1/B5/B9) instead of a parallel
  side-channel accumulator.

  ## Invariants (§84), checked on every sample

  Every case asserts on the real returned `HookReactor.Result.t()` AND an
  independent post-state read (`AshA2A.Chicago.Fixtures.HooksCascade.signals/1`
  -> `Ash.read!/1`), never on "was a function called": `no_match_control`
  must evaluate without firing and leave zero Signal rows;
  `single_match`/`multi_match_within_bound` must fire every admitted hook and
  leave exactly one Signal row per intent; `replay_same_delta` must yield the
  SAME `intent_id` both deliveries, observe idempotency outcome `:new` then
  `:seen`, and leave exactly ONE Signal row after two deliveries (no
  duplicated consequence). Any violation is an invariant failure in the raw
  result, never silently dropped.
  """

  alias AshA2A.Chicago.Bench
  alias AshA2A.Chicago.Fixtures.HooksCascade, as: F
  alias AshA2A.Semantic.HookReactor
  alias AshA2A.Semantic.HookReactor.Engine

  @id "SA2A-B3"

  @cascade_start [:ash_a2a, :hook_reactor, :cascade, :start]
  @hook_evaluate [:ash_a2a, :hook_reactor, :hook, :evaluate]
  @intent_constructed [:ash_a2a, :hook_reactor, :intent, :constructed]
  @intent_idempotency [:ash_a2a, :hook_reactor, :intent, :idempotency]
  @cascade_stop [:ash_a2a, :hook_reactor, :cascade, :stop]

  @events [
    @cascade_start,
    @hook_evaluate,
    @intent_constructed,
    @intent_idempotency,
    @cascade_stop
  ]

  @cases ["no_match_control", "single_match", "multi_match_within_bound", "replay_same_delta"]

  @spec id() :: String.t()
  def id, do: @id

  @doc "Telemetry events the benchmark times."
  @spec events() :: [[atom()]]
  def events, do: @events

  @doc "Every §87 case this benchmark runs."
  @spec cases() :: [String.t()]
  def cases, do: @cases

  @doc """
  Runs the benchmark. Returns `{:ok, body}` or `{:blocked, detail}` when the
  real GraphLaw engine is not runnable on this host (never a fake engine).

  Options: `:iterations`, `:warmup` (passed to `AshA2A.Chicago.Bench.measure/2`).
  """
  @spec run(keyword()) :: {:ok, map()} | {:blocked, String.t()}
  def run(opts \\ []) do
    case Engine.open([]) do
      {:error, %{detail: detail}} ->
        {:blocked, "real GraphLaw engine unavailable: #{inspect(detail)}"}

      {:ok, runtime} ->
        try do
          F.with_env(fn env -> {:ok, measure(runtime, env, opts)} end)
        after
          Engine.close(runtime)
        end
    end
  end

  defp measure(runtime, env, opts) do
    ref = make_ref()

    :ok =
      :telemetry.attach_many({__MODULE__, ref}, @events, &__MODULE__.handle_event/4, %{
        pid: self(),
        ref: ref
      })

    try do
      handlers = length(:telemetry.list_handlers(@cascade_stop))

      measured =
        Bench.measure(
          fn _phase, _i -> Enum.map(@cases, &case_sample(&1, runtime, env, ref)) end,
          opts
        )

      stage_latency =
        measured["samples"]
        |> Enum.flat_map(&Enum.to_list(&1["phases_us"]))
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Map.new(fn {phase, values} -> {phase, Bench.distribution(values)} end)

      Map.merge(measured, %{
        "benchmark" => "B3 Knowledge Hook reflex",
        "rfc_sections" => ["§84", "§87"],
        "sut" => %{
          "boundary" => "AshA2A.Semantic.HookReactor.run/2",
          "engine_wasm_digest" => runtime.wasm_digest
        },
        "fixture" => %{
          "source" =>
            "AshA2A.Chicago.Fixtures.HooksCascade (shared with AshA2A.Chicago.Courts.KnowledgeHooks / SA2A-HOOK)",
          "ns" => F.ns(),
          "capability" => F.capability(),
          "cases" => @cases
        },
        "cases_reported_separately" => true,
        "stage_latency_us" => stage_latency,
        "evidence_handlers_attached" => handlers,
        "notes" => [
          "hook meta-admission (HookReactor.admit/2) runs before the timer starts and is excluded from every timed region -- SA2A-B1's scope, not B3's",
          "every case runs with project: false (one generation only) -- cascade depth/fan-out-across-generations/quiescence-under-load is SA2A-B6's scope",
          "authority decision and CommandBus/BRCE latency are SA2A-B5's scope; this benchmark times only the hook_reactor boundary's own telemetry",
          "hooks_evaluated/hooks_fired/intent_count/delta_size are integer counts carried in the same phases map as microsecond latencies, the same convention SA2A-B1 uses for its own derived (non-raw-stage) integers",
          "replay_same_delta reports idempotency_check_new_us and idempotency_check_seen_us separately instead of pooling them",
          "stage_latency_us pools all four cases' phase entries together (parity with SA2A-B1); by_case below breaks the same phases out per case"
        ],
        "highlights" => %{
          "hook_evaluation_p50_us" => get_in(stage_latency, ["hook_evaluation_us", "p50"]),
          "intent_construction_p50_us" =>
            get_in(stage_latency, ["intent_construction_us", "p50"]),
          "idempotency_check_new_p50_us" =>
            get_in(stage_latency, ["idempotency_check_new_us", "p50"]),
          "idempotency_check_seen_p50_us" =>
            get_in(stage_latency, ["idempotency_check_seen_us", "p50"]),
          "cascade_total_p50_us" => get_in(stage_latency, ["cascade_total_us", "p50"])
        }
      })
    after
      :telemetry.detach({__MODULE__, ref})
      _ = drain(ref)
    end
  end

  # --- cases -------------------------------------------------------------------

  defp case_sample("no_match_control", runtime, env, ref) do
    subject = unique_subject("nomatch")
    hook = F.hook("sa2a-b3-nomatch-" <> subject, "Intrusion", "Alert", subject)
    delta = F.typed_delta("Unrelated", "urn:sa2a:zone:" <> subject)
    bounds = F.bounds!(1, 1, 1)

    {result, duration, timeline} = run_episode(runtime, env, ref, [hook], delta, bounds)
    rows = F.signals(subject)

    %{
      case: "no_match_control",
      duration_us: duration,
      outcome: to_string(result.outcome),
      phases: episode_phases(timeline, result),
      invariant: no_match_invariant(result, rows)
    }
  end

  defp case_sample("single_match", runtime, env, ref) do
    subject = unique_subject("single")
    hook = F.hook("sa2a-b3-single-" <> subject, "Intrusion", "Alert", subject)
    delta = F.typed_delta("Intrusion", "urn:sa2a:zone:" <> subject)
    bounds = F.bounds!(1, 1, 1)

    {result, duration, timeline} = run_episode(runtime, env, ref, [hook], delta, bounds)
    rows = F.signals(subject)

    %{
      case: "single_match",
      duration_us: duration,
      outcome: to_string(result.outcome),
      phases: episode_phases(timeline, result),
      invariant: single_match_invariant(result, rows)
    }
  end

  defp case_sample("multi_match_within_bound", runtime, env, ref) do
    subject = unique_subject("multi")
    zone = "urn:sa2a:zone:" <> subject
    hook_a = F.hook("sa2a-b3-multi-a-" <> subject, "Intrusion", "Alert", subject)
    hook_b = F.hook("sa2a-b3-multi-b-" <> subject, "Intrusion", "Alert", subject)
    delta = F.typed_delta("Intrusion", zone)
    bounds = F.bounds!(1, 2, 1)

    {result, duration, timeline} = run_episode(runtime, env, ref, [hook_a, hook_b], delta, bounds)
    rows = F.signals(subject)

    %{
      case: "multi_match_within_bound",
      duration_us: duration,
      outcome: to_string(result.outcome),
      phases: episode_phases(timeline, result),
      invariant: multi_match_invariant(result, rows)
    }
  end

  defp case_sample("replay_same_delta", runtime, env, ref) do
    subject = unique_subject("replay")
    hook = F.hook("sa2a-b3-replay-" <> subject, "Intrusion", "Alert", subject)
    delta = F.typed_delta("Intrusion", "urn:sa2a:zone:" <> subject)
    bounds = F.bounds!(1, 1, 1)

    %{admission: admission} = HookReactor.admit([hook], runtime: runtime)
    _ = drain(ref)
    started = System.monotonic_time(:microsecond)

    ep1 = run!(runtime, env, admission, [hook], delta, bounds)
    timeline1 = drain(ref)

    ep2 = run!(runtime, env, admission, [hook], delta, bounds)
    timeline2 = drain(ref)

    duration = System.monotonic_time(:microsecond) - started
    rows = F.signals(subject)

    %{
      case: "replay_same_delta",
      duration_us: duration,
      outcome: "#{ep1.outcome}->#{ep2.outcome}",
      phases: replay_phases(timeline1, timeline2, ep1, ep2),
      invariant: replay_invariant(ep1, ep2, timeline1, timeline2, rows)
    }
  end

  defp run_episode(runtime, env, ref, hooks, delta, bounds) do
    %{admission: admission} = HookReactor.admit(hooks, runtime: runtime)
    _ = drain(ref)
    started = System.monotonic_time(:microsecond)
    result = run!(runtime, env, admission, hooks, delta, bounds)
    duration = System.monotonic_time(:microsecond) - started
    timeline = drain(ref)
    {result, duration, timeline}
  end

  defp run!(runtime, env, admission, hooks, delta, bounds) do
    F.run!(runtime, env, admission,
      hooks: hooks,
      delta: delta,
      principal: env.granted,
      bounds: bounds,
      parallelism: 1,
      project: false
    )
  end

  defp unique_subject(tag), do: "#{tag}-#{System.unique_integer([:positive, :monotonic])}"

  # --- phases --------------------------------------------------------------------

  defp episode_phases(timeline, result) do
    start = first(timeline, @cascade_start)
    stop = first(timeline, @cascade_stop)

    %{
      "cascade_total_us" => gap(start, stop),
      "hook_evaluation_us" => sum_duration_us(timeline, @hook_evaluate),
      "intent_construction_us" => sum_duration_us(timeline, @intent_constructed),
      "idempotency_check_us" => sum_duration_us(timeline, @intent_idempotency),
      "delta_size" => result.delta_size,
      "hooks_evaluated" => length(result.evaluations),
      "hooks_fired" => Enum.count(result.evaluations, &(&1[:outcome] == :fired)),
      "intent_count" => length(result.intents)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp replay_phases(timeline1, timeline2, ep1, ep2) do
    start1 = first(timeline1, @cascade_start)
    stop2 = first(timeline2, @cascade_stop)

    %{
      "cascade_total_us" => gap(start1, stop2),
      "hook_evaluation_us" =>
        add(
          sum_duration_us(timeline1, @hook_evaluate),
          sum_duration_us(timeline2, @hook_evaluate)
        ),
      "intent_construction_us" =>
        add(
          sum_duration_us(timeline1, @intent_constructed),
          sum_duration_us(timeline2, @intent_constructed)
        ),
      "idempotency_check_new_us" => sum_duration_us(timeline1, @intent_idempotency),
      "idempotency_check_seen_us" => sum_duration_us(timeline2, @intent_idempotency),
      "delta_size" => ep1.delta_size,
      "hooks_evaluated" => length(ep1.evaluations) + length(ep2.evaluations),
      "hooks_fired" =>
        Enum.count(ep1.evaluations, &(&1[:outcome] == :fired)) +
          Enum.count(ep2.evaluations, &(&1[:outcome] == :fired)),
      "intent_count" => length(ep1.intents) + length(ep2.intents)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp add(nil, nil), do: nil
  defp add(a, nil), do: a
  defp add(nil, b), do: b
  defp add(a, b), do: a + b

  # --- invariants (§84) ----------------------------------------------------------

  defp no_match_invariant(result, rows) do
    cond do
      length(result.evaluations) != 1 ->
        {:error,
         "expected 1 hook evaluation for no_match_control, got #{length(result.evaluations)}"}

      Enum.any?(result.evaluations, &(&1[:outcome] == :fired)) ->
        {:error, "no_match_control: unrelated delta fired a hook it must not match"}

      result.intents != [] ->
        {:error, "no_match_control produced #{length(result.intents)} intent(s)"}

      result.outcome != :quiescent ->
        {:error, "no_match_control reached #{inspect(result.outcome)}, not :quiescent"}

      rows != [] ->
        {:error, "no_match_control produced #{length(rows)} Signal row(s)"}

      true ->
        :ok
    end
  end

  defp single_match_invariant(result, rows) do
    cond do
      length(result.evaluations) != 1 ->
        {:error, "expected 1 hook evaluation for single_match, got #{length(result.evaluations)}"}

      length(result.intents) != 1 ->
        {:error, "expected exactly 1 intent for single_match, got #{length(result.intents)}"}

      result.outcome != :quiescent ->
        {:error, "single_match reached #{inspect(result.outcome)}, not :quiescent"}

      length(rows) != 1 ->
        {:error, "expected exactly 1 Signal row for single_match, got #{length(rows)}"}

      hd(rows).kind != "Alert" ->
        {:error, "single_match Signal row has kind #{inspect(hd(rows).kind)}, not \"Alert\""}

      true ->
        :ok
    end
  end

  defp multi_match_invariant(result, rows) do
    fan_out_admitted? =
      Enum.any?(
        result.bound_decisions,
        &(&1.bound == :fan_out and &1.outcome == :admitted and &1.requested == 2)
      )

    cond do
      length(result.evaluations) != 2 ->
        {:error,
         "expected 2 hook evaluations for multi_match_within_bound, got #{length(result.evaluations)}"}

      Enum.count(result.evaluations, &(&1[:outcome] == :fired)) != 2 ->
        {:error, "multi_match_within_bound: expected both hooks to fire"}

      length(result.intents) != 2 ->
        {:error,
         "expected exactly 2 intents for multi_match_within_bound, got #{length(result.intents)}"}

      not fan_out_admitted? ->
        {:error,
         "multi_match_within_bound: fan-out bound (2 requested) was not admitted: #{inspect(result.bound_decisions)}"}

      result.outcome != :quiescent ->
        {:error, "multi_match_within_bound reached #{inspect(result.outcome)}, not :quiescent"}

      length(rows) != 2 ->
        {:error,
         "expected exactly 2 Signal rows for multi_match_within_bound, got #{length(rows)}"}

      true ->
        :ok
    end
  end

  defp replay_invariant(ep1, ep2, timeline1, timeline2, rows) do
    ep1_intent_id = ep1.intents |> List.first() |> then(&(&1 && &1.intent_id))
    ep2_intent_id = ep2.intents |> List.first() |> then(&(&1 && &1.intent_id))
    idempotency1 = idempotency_outcome(timeline1)
    idempotency2 = idempotency_outcome(timeline2)

    cond do
      length(ep1.intents) != 1 or length(ep2.intents) != 1 ->
        {:error,
         "expected exactly 1 intent per replay delivery, got #{length(ep1.intents)} then #{length(ep2.intents)}"}

      ep1_intent_id != ep2_intent_id ->
        {:error,
         "replay produced divergent intent ids: #{inspect(ep1_intent_id)} vs #{inspect(ep2_intent_id)}"}

      ep1.outcome != :quiescent or ep2.outcome != :quiescent ->
        {:error,
         "replay reached #{inspect(ep1.outcome)} then #{inspect(ep2.outcome)}, not :quiescent both times"}

      idempotency1 != :new ->
        {:error, "first delivery idempotency outcome was #{inspect(idempotency1)}, not :new"}

      idempotency2 != :seen ->
        {:error,
         "second (replayed) delivery idempotency outcome was #{inspect(idempotency2)}, not :seen"}

      length(rows) != 1 ->
        {:error,
         "replay of the same delta produced #{length(rows)} Signal row(s), expected exactly 1 (no duplicate consequence)"}

      true ->
        :ok
    end
  end

  defp idempotency_outcome(timeline) do
    case first(timeline, @intent_idempotency) do
      nil -> nil
      entry -> entry.metadata[:outcome]
    end
  end

  # --- own telemetry collector ---------------------------------------------------
  #
  # AshA2A.Chicago.Bench.Timeline keeps only arrival-order gaps between the
  # FIRST occurrence of each event, which is exact for B1/B5's
  # one-occurrence-per-stage episodes but ambiguous here: `hook.evaluate`,
  # `intent.constructed` and `intent.idempotency` each fire once PER HOOK (or
  # per fired hook), so this module reads the real `:duration_us`
  # HookReactor itself measured internally straight off the telemetry
  # measurements map instead of re-deriving it from observer-side gaps.

  @doc false
  def handle_event(event, measurements, metadata, %{pid: pid, ref: ref}) do
    at = System.monotonic_time(:microsecond)
    send(pid, {ref, event, at, measurements, metadata})
    :ok
  end

  defp drain(ref), do: drain(ref, [])

  defp drain(ref, acc) do
    receive do
      {^ref, event, at_us, measurements, metadata} ->
        entry = %{event: event, at_us: at_us, measurements: measurements, metadata: metadata}
        drain(ref, [entry | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp first(timeline, event), do: Enum.find(timeline, &(&1.event == event))

  defp all(timeline, event), do: Enum.filter(timeline, &(&1.event == event))

  defp gap(nil, _), do: nil
  defp gap(_, nil), do: nil
  defp gap(%{at_us: a}, %{at_us: b}), do: b - a

  defp sum_duration_us(timeline, event) do
    case all(timeline, event) do
      [] -> nil
      entries -> Enum.sum(Enum.map(entries, &(&1.measurements[:duration_us] || 0)))
    end
  end
end
