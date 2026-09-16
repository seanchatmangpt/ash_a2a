defmodule AshA2A.Chicago.Courts.KnowledgeHooks do
  @moduledoc """
  RFC-SA2A-002 §60 Knowledge Hook, §61 Hook Meta-Admission and §62 Hook
  Determinism/Idempotency courts (court id `SA2A-HOOK`).

      Hook ≠ DO        HookOutput ⇒ SemanticIntent        SemanticIntent ⇏ Authority

  Subject under qualification: `AshA2A.Semantic.HookReactor` (meta-admission,
  real-engine condition evaluation, intent construction, bounded routing)
  and the consequence boundary it must not bypass, `AshA2A.CommandBus`.

  Real collaborators only: the real praxis-graphlaw wasm in an in-BEAM
  Wasmtime session decides every hook condition; the real CommandBus, a real
  `AshA2A.ReceiptStore.Memory`, a real `AshA2A.Authority.Broker.InMemory` and
  the real ETS `Signal` resource carry consequence; post-state is read back
  through `Ash.read!/1`.
  """

  use AshA2A.Chicago.Court

  alias AshA2A.{Authority, Identity}
  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Fixtures.HooksCascade, as: F
  alias AshA2A.Semantic.HookReactor
  alias AshA2A.Semantic.HookReactor.Engine

  @court "SA2A-HOOK"

  @impl true
  def id, do: @court
  @impl true
  def title, do: "Knowledge hooks: Hook ≠ DO, hook meta-admission, determinism and idempotency"
  @impl true
  def gate, do: 7
  @impl true
  def profile, do: :logic
  @impl true
  def rfc_sections, do: ["§38", "§60", "§61", "§62", "§100"]

  @impl true
  def ocel_mappings, do: F.mappings(__MODULE__)

  @consequence {:any,
                [
                  {:observed, "brce.actuate.start"},
                  {:observed, "dispatch.start"},
                  {:observed, "brce.commit"}
                ]}

  @fired_or_consequence {:any,
                         [
                           {:observed, "hook.evaluate", %{"outcome" => "fired"}},
                           {:observed, "hook.intent.constructed"},
                           {:observed, "brce.actuate.start"},
                           {:observed, "dispatch.start"}
                         ]}

  @impl true
  def falsifiers do
    [
      negative(
        "001",
        invariant:
          "Hook ≠ DO ∧ SemanticIntent ⇏ Authority: a fired hook's consequence-bearing intent yields zero consequence without a grant",
        stimulus:
          "admitted guarded alarm hook fires on a real reading delta; the reflex principal holds no broker grant for Signal.emit",
        boundary: "AshA2A.Semantic.HookReactor routing -> AshA2A.CommandBus admission",
        forbidden_outcome:
          "CommandBus actuation, dispatch, commit, or a Signal row caused by the intent",
        attempt_evidence:
          "hook.evaluate fired + hook.intent.constructed + a CommandBus admission decision for the intent's command",
        survival_evidence:
          "brce.actuate.start / dispatch.start / brce.commit attributed to the stimulus; Signal row in Ash.read!",
        guard:
          "Intent has no authority field; HookReactor.route/4 asks Grant.authorize/3; CommandBus.admit/2 authority_required",
        failure_class: :authority_failure,
        rfc_sections: ["§60"],
        attempt_predicate:
          {:all,
           [
             {:observed, "hook.evaluate", %{"outcome" => "fired"}},
             {:observed, "brce.admission"},
             {:precedes, "hook.intent.constructed", "brce.admission", "command"}
           ]},
        outcome_predicate: @consequence
      ),
      negative(
        "002",
        invariant:
          "A hook MUST NOT bypass authority: a hook whose intent template carries a minted Authority is refused at meta-admission",
        stimulus:
          "hook with intent.authority = a real %AshA2A.Authority{} for the ungranted principal, submitted to admission and then run on a matching delta",
        boundary: "AshA2A.Semantic.HookReactor.admit/2 (Hook.validate/1 authority scan)",
        forbidden_outcome:
          "the authority-carrying hook admitted, fired, or any actuation attributed to the stimulus",
        attempt_evidence:
          "a hook.admission decision for the authority-carrying hook and a hook.evaluate for it",
        survival_evidence: "hook.admission admitted, hook.evaluate fired, brce.actuate.start",
        guard: "Hook.validate/1 no_authority/1",
        failure_class: :authority_failure,
        rfc_sections: ["§60"],
        attempt_predicate: {:all, [{:observed, "hook.admission"}, {:observed, "hook.evaluate"}]},
        outcome_predicate:
          {:any,
           [
             {:observed, "hook.admission", %{"outcome" => "admitted"}},
             {:observed, "hook.evaluate", %{"outcome" => "fired"}},
             {:observed, "brce.actuate.start"}
           ]}
      ),
      negative(
        "003",
        invariant:
          "An unadmitted hook that happens to match a graph delta MUST NOT fire with production standing",
        stimulus:
          "a never-admitted hook whose trigger matches the delta (verified by the real engine after the run), granted principal",
        boundary: "AshA2A.Semantic.HookReactor evaluation standing check",
        forbidden_outcome: "hook fired, intent constructed, or actuation",
        attempt_evidence:
          "hook.evaluate decision for the unadmitted hook over a delta its trigger matches (engine-checked by the court)",
        survival_evidence:
          "hook.evaluate fired, hook.intent.constructed, brce.actuate.start, Signal row",
        guard: "HookReactor.evaluate/6 admission digest membership",
        failure_class: :meta_admission_failure,
        rfc_sections: ["§61"],
        attempt_predicate: {:observed, "hook.evaluate"},
        outcome_predicate: @fired_or_consequence
      ),
      negative(
        "004",
        invariant:
          "Condition identity binds standing: a hook whose condition is mutated after admission has no admitted standing",
        stimulus:
          "admit a hook, then replace its trigger (same id/revision, stale condition digest) with one matching a different class; run the mutant on a delta of that class, granted principal",
        boundary: "AshA2A.Semantic.HookReactor evaluation standing check (Hook.digest/1)",
        forbidden_outcome: "mutated hook fired, intent constructed, or actuation",
        attempt_evidence:
          "hook.admission admitted (original) + a hook.evaluate decision for the mutant over a delta its trigger matches",
        survival_evidence: "hook.evaluate fired, hook.intent.constructed, brce.actuate.start",
        guard: "Hook.digest/1 covers trigger/guard/condition_digest; admission records digests",
        failure_class: :meta_admission_failure,
        rfc_sections: ["§61"],
        attempt_predicate:
          {:all,
           [
             {:observed, "hook.admission", %{"outcome" => "admitted"}},
             {:observed, "hook.evaluate"}
           ]},
        outcome_predicate: @fired_or_consequence
      ),
      negative(
        "005",
        invariant:
          "Hook provenance is required before a hook can participate in canonical production reflex",
        stimulus:
          "hook with empty provenance submitted to meta-admission, then run on a matching delta with a granted principal",
        boundary: "AshA2A.Semantic.HookReactor.admit/2 (Hook.validate/1 provenance)",
        forbidden_outcome: "provenance-less hook admitted, fired, or actuation",
        attempt_evidence:
          "a hook.admission decision for the provenance-less hook and a hook.evaluate for it",
        survival_evidence: "hook.admission admitted, hook.evaluate fired, brce.actuate.start",
        guard: "Hook.validate/1 provenance/1",
        failure_class: :meta_admission_failure,
        rfc_sections: ["§61"],
        attempt_predicate: {:all, [{:observed, "hook.admission"}, {:observed, "hook.evaluate"}]},
        outcome_predicate:
          {:any,
           [
             {:observed, "hook.admission", %{"outcome" => "admitted"}},
             {:observed, "hook.evaluate", %{"outcome" => "fired"}},
             {:observed, "brce.actuate.start"}
           ]}
      ),
      Falsifier.new!(
        id: "SA2A-HOOK-006",
        court_id: @court,
        kind: :positive_control,
        invariant:
          "Discrimination: an admitted, well-formed hook with a granted principal produces exactly one receipted consequence through BRCE",
        stimulus:
          "admit the guarded alarm hook, run it on a reading of an armed sensor with a granted principal",
        boundary: "HookReactor meta-admission + engine evaluation + CommandBus",
        attempt_evidence: "hook.intent.constructed",
        survival_evidence:
          "hook admitted and fired; intent precedes CommandBus admission of the same command; prepare precedes actuation; commit; one Signal row",
        rfc_sections: ["§60", "§61", "§100"],
        attempt_predicate: {:observed, "hook.intent.constructed"},
        outcome_predicate:
          {:all,
           [
             {:observed, "hook.admission", %{"outcome" => "admitted"}},
             {:observed, "hook.evaluate", %{"outcome" => "fired"}},
             {:precedes, "hook.intent.constructed", "brce.admission", "command"},
             {:precedes, "brce.prepare", "brce.actuate.start", "command"},
             {:observed, "brce.commit", %{"outcome" => "committed"}},
             {:count, "brce.actuate.start", :eq, 1}
           ]}
      ),
      negative(
        "007",
        invariant:
          "Same admitted state + same delta + same hook revision ⇒ equivalent verdict and intent identity; replay never multiplies consequence",
        stimulus: "deliver the byte-identical delta twice to the same admitted hook set",
        boundary: "Intent identity (HookReactor.Intent.build/4) -> CommandBus claim/replay",
        forbidden_outcome:
          "divergent generation-1 verdicts or intent ids, a second actuation, or a claim conflict",
        attempt_evidence: "two episodes, two constructed intents, one committed consequence",
        survival_evidence:
          "brce.actuate.start count >= 2 or brce.claim refused; court-side intent id / verdict comparison; Signal rows > 1",
        guard: "Intent.build/4 identity over hook digest + canonical delta digest + template",
        failure_class: :replay_failure,
        rfc_sections: ["§62"],
        attempt_predicate:
          {:all,
           [
             {:count, "hook.cascade.start", :eq, 2},
             {:count, "hook.intent.constructed", :eq, 2},
             {:observed, "brce.commit", %{"outcome" => "committed"}}
           ]},
        outcome_predicate:
          {:any,
           [
             {:count, "brce.actuate.start", :gte, 2},
             {:observed, "brce.claim", %{"outcome" => "refused"}}
           ]}
      ),
      negative(
        "008",
        invariant:
          "Triple ordering, prefix labels and blank-node labels do not change hook verdict or intent identity",
        stimulus:
          "deliver one delta, then the same graph with statements reordered, a different prefix label and relabelled blank nodes",
        boundary: "Engine.canonical_delta/1 (RDFC-1.0) -> Intent identity -> CommandBus claim",
        forbidden_outcome:
          "divergent delta digest, verdicts or intent ids, a second actuation, or a claim conflict",
        attempt_evidence: "two episodes, two constructed intents, one committed consequence",
        survival_evidence:
          "brce.actuate.start count >= 2 or brce.claim refused; court-side digest/intent comparison",
        guard: "Engine.canonical_delta/1 uses RDF.Graph.canonical_hash/1, not raw bytes",
        failure_class: :replay_failure,
        rfc_sections: ["§62"],
        attempt_predicate:
          {:all,
           [
             {:count, "hook.cascade.start", :eq, 2},
             {:count, "hook.intent.constructed", :eq, 2},
             {:observed, "brce.commit", %{"outcome" => "committed"}}
           ]},
        outcome_predicate:
          {:any,
           [
             {:count, "brce.actuate.start", :gte, 2},
             {:observed, "brce.claim", %{"outcome" => "refused", "code" => "command_conflict"}}
           ]}
      ),
      negative(
        "009",
        invariant:
          "Duplicate delivery (idempotency identity reuse) MUST NOT silently multiply consequence, even concurrently",
        stimulus: "deliver the same delta to two concurrent reactor episodes at once",
        boundary: "Intent identity -> CommandBus claim (execute | in_flight | replay)",
        forbidden_outcome: "two actuations or two Signal rows for one intent",
        attempt_evidence: "two episodes, two CommandBus claims, one committed consequence",
        survival_evidence: "brce.actuate.start count >= 2; Signal rows > 1",
        guard: "Intent.command_id/1 reused across deliveries; ReceiptStore claim",
        failure_class: :actuation_failure,
        rfc_sections: ["§62", "§38"],
        attempt_predicate:
          {:all,
           [
             {:count, "hook.cascade.start", :eq, 2},
             {:count, "brce.claim", :eq, 2},
             {:observed, "brce.commit", %{"outcome" => "committed"}}
           ]},
        outcome_predicate: {:count, "brce.actuate.start", :gte, 2}
      ),
      negative(
        "010",
        invariant: "An unrelated graph delta does not fire a hook",
        stimulus:
          "admitted guarded alarm hook, granted principal, armed sensor; delta asserts only a location, no reading",
        boundary: "real GraphLaw N3_DENIAL evaluation of the trigger over the delta",
        forbidden_outcome: "hook fired, intent constructed, or actuation",
        attempt_evidence: "hook.evaluate with trigger=false (the engine evaluated the trigger)",
        survival_evidence: "hook.evaluate fired, hook.intent.constructed, brce.actuate.start",
        guard: "HookReactor.evaluate/6 fires only when the engine reports a trigger binding",
        failure_class: :meta_admission_failure,
        rfc_sections: ["§62"],
        attempt_predicate: {:observed, "hook.evaluate", %{"trigger" => "false"}},
        outcome_predicate: @fired_or_consequence
      ),
      negative(
        "011",
        invariant:
          "Condition-false control: a delta that matches the trigger but not the guard does not fire",
        stimulus:
          "admitted guarded alarm hook, granted principal; reading asserted for an UNARMED sensor while another sensor is armed",
        boundary: "real GraphLaw N3_DENIAL evaluation of the guard over the post-state",
        forbidden_outcome: "hook fired, intent constructed, or actuation",
        attempt_evidence:
          "hook.evaluate with trigger=true and guard=false (both engine-evaluated)",
        survival_evidence: "hook.evaluate fired, hook.intent.constructed, brce.actuate.start",
        guard: "HookReactor.evaluate/6 requires trigger ∧ guard",
        failure_class: :meta_admission_failure,
        rfc_sections: ["§62"],
        attempt_predicate:
          {:observed, "hook.evaluate", %{"trigger" => "true", "guard" => "false"}},
        outcome_predicate: @fired_or_consequence
      ),
      negative(
        "012",
        invariant:
          "Condition identity is semantic, not nominal: a self-satisfying condition (one that asserts the triple it matches) is not admitted",
        stimulus:
          "hook whose trigger document plants `<urn:planted> a h:Always` next to `{ ?s a h:Always } => false`, run on an unrelated delta with a granted principal",
        boundary:
          "AshA2A.Semantic.HookReactor.admit/2 (condition shape + real-engine empty-graph witness)",
        forbidden_outcome:
          "self-satisfying hook admitted, fired on the unrelated delta, or actuation",
        attempt_evidence:
          "a hook.admission decision for the self-satisfying hook and a hook.evaluate for it over an unrelated delta",
        survival_evidence: "hook.admission admitted, hook.evaluate fired, brce.actuate.start",
        guard: "Hook.condition_shape/2 and HookReactor.condition_witness/4 empty-graph check",
        failure_class: :meta_admission_failure,
        rfc_sections: ["§61"],
        attempt_predicate: {:all, [{:observed, "hook.admission"}, {:observed, "hook.evaluate"}]},
        outcome_predicate:
          {:any,
           [
             {:observed, "hook.admission", %{"outcome" => "admitted"}},
             {:observed, "hook.evaluate", %{"outcome" => "fired"}},
             {:observed, "brce.actuate.start"}
           ]}
      )
    ]
  end

  defp negative(suffix, fields) do
    Falsifier.new!([id: "#{@court}-#{suffix}", court_id: @court, kind: :negative] ++ fields)
  end

  # --- execution --------------------------------------------------------------

  @impl true
  def run(%Context{} = ctx) do
    falsifiers = falsifiers()

    case Engine.open() do
      {:error, reason} ->
        Enum.map(
          falsifiers,
          &Result.blocked(&1, "real GraphLaw engine unavailable: #{inspect(reason)}")
        )

      {:ok, runtime} ->
        try do
          F.with_env(fn env ->
            Enum.map(falsifiers, fn f ->
              F.guarded(f, fn -> execute(f.id, f, ctx, runtime, env) end)
            end)
          end)
        after
          Engine.close(runtime)
        end
    end
  end

  defp execute("SA2A-HOOK-001", f, ctx, runtime, env) do
    subject = subject(env, f)
    sensor = "urn:sa2a:sensor:" <> subject
    hook = F.alarm_hook("sa2a-alarm-001", subject)

    ep =
      Context.stimulus(ctx, f, fn ->
        F.episode(runtime, env,
          hooks: [hook],
          delta: F.reading_delta(sensor, 42),
          base: F.armed_base(sensor),
          principal: env.ungranted,
          bounds: F.bounds!(2, 2, 1)
        )
      end)

    rows = F.signals(subject)

    Result.negative(f,
      attempt_observed?:
        F.seen?(ctx, f, "hook.intent.constructed") and F.seen?(ctx, f, "brce.admission"),
      forbidden_outcome_observed?:
        rows != [] or F.seen?(ctx, f, "brce.actuate.start") or F.seen?(ctx, f, "dispatch.start"),
      evidence: episode_evidence(ep, rows)
    )
  end

  defp execute("SA2A-HOOK-002", f, ctx, runtime, env) do
    subject = subject(env, f)
    smuggled = Authority.new(Identity.principal(env.ungranted), F.capability())

    hook =
      F.hook("sa2a-smuggler-002", "Intrusion", "Alert", subject,
        intent_extra: %{authority: smuggled}
      )

    ep =
      Context.stimulus(ctx, f, fn ->
        F.episode(runtime, env,
          hooks: [hook],
          delta: F.typed_delta("Intrusion", "urn:sa2a:zone:" <> subject),
          principal: env.ungranted,
          bounds: F.bounds!(2, 2, 1)
        )
      end)

    rows = F.signals(subject)

    Result.negative(f,
      attempt_observed?: F.seen?(ctx, f, "hook.admission") and F.seen?(ctx, f, "hook.evaluate"),
      forbidden_outcome_observed?:
        F.seen?(ctx, f, "hook.admission", %{"outcome" => "admitted"}) or
          F.seen?(ctx, f, "hook.evaluate", %{"outcome" => "fired"}) or
          F.seen?(ctx, f, "brce.actuate.start") or rows != [],
      evidence: episode_evidence(ep, rows)
    )
  end

  defp execute("SA2A-HOOK-003", f, ctx, runtime, env) do
    subject = subject(env, f)
    hook = F.hook("sa2a-unadmitted-003", "Intrusion", "Alert", subject)
    delta = F.typed_delta("Intrusion", "urn:sa2a:zone:" <> subject)

    ep =
      Context.stimulus(ctx, f, fn ->
        F.episode(runtime, env,
          hooks: [hook],
          admit: [],
          delta: delta,
          principal: env.granted,
          bounds: F.bounds!(2, 2, 1)
        )
      end)

    rows = F.signals(subject)
    would_match = would_match?(runtime, delta, hook.trigger)

    Result.negative(f,
      attempt_observed?: would_match == true and F.seen?(ctx, f, "hook.evaluate"),
      forbidden_outcome_observed?: fired_or_consequence?(ctx, f) or rows != [],
      evidence: Map.put(episode_evidence(ep, rows), "trigger_matches_delta", would_match)
    )
  end

  defp execute("SA2A-HOOK-004", f, ctx, runtime, env) do
    subject = subject(env, f)
    original = F.hook("sa2a-mutant-004", "Intrusion", "Alert", subject)
    mutant = %{original | trigger: F.condition("{ ?s a h:Breach }")}
    delta = F.typed_delta("Breach", "urn:sa2a:zone:" <> subject)

    ep =
      Context.stimulus(ctx, f, fn ->
        F.episode(runtime, env,
          hooks: [mutant],
          admit: [original],
          delta: delta,
          principal: env.granted,
          bounds: F.bounds!(2, 2, 1)
        )
      end)

    rows = F.signals(subject)
    would_match = would_match?(runtime, delta, mutant.trigger)

    Result.negative(f,
      attempt_observed?:
        would_match == true and
          F.seen?(ctx, f, "hook.admission", %{"outcome" => "admitted"}) and
          F.seen?(ctx, f, "hook.evaluate"),
      forbidden_outcome_observed?: fired_or_consequence?(ctx, f) or rows != [],
      evidence:
        ep
        |> episode_evidence(rows)
        |> Map.put("mutant_trigger_matches_delta", would_match)
        |> Map.put("declared_condition_digest", mutant.condition_digest)
    )
  end

  defp execute("SA2A-HOOK-005", f, ctx, runtime, env) do
    subject = subject(env, f)
    hook = F.hook("sa2a-orphan-005", "Intrusion", "Alert", subject, provenance: %{})

    ep =
      Context.stimulus(ctx, f, fn ->
        F.episode(runtime, env,
          hooks: [hook],
          delta: F.typed_delta("Intrusion", "urn:sa2a:zone:" <> subject),
          principal: env.granted,
          bounds: F.bounds!(2, 2, 1)
        )
      end)

    rows = F.signals(subject)

    Result.negative(f,
      attempt_observed?: F.seen?(ctx, f, "hook.admission") and F.seen?(ctx, f, "hook.evaluate"),
      forbidden_outcome_observed?:
        F.seen?(ctx, f, "hook.admission", %{"outcome" => "admitted"}) or
          fired_or_consequence?(ctx, f) or rows != [],
      evidence: episode_evidence(ep, rows)
    )
  end

  defp execute("SA2A-HOOK-006", f, ctx, runtime, env) do
    subject = subject(env, f)
    sensor = "urn:sa2a:sensor:" <> subject
    hook = F.alarm_hook("sa2a-alarm-006", subject)

    ep =
      Context.stimulus(ctx, f, fn ->
        F.episode(runtime, env,
          hooks: [hook],
          delta: F.reading_delta(sensor, 42),
          base: F.armed_base(sensor),
          principal: env.granted,
          bounds: F.bounds!(2, 2, 1)
        )
      end)

    rows = F.signals(subject)

    Result.positive(f,
      attempt_observed?: F.seen?(ctx, f, "hook.intent.constructed"),
      expected_outcome_observed?:
        length(rows) == 1 and hd(rows).kind == "Alert" and
          F.count(ctx, f, "brce.actuate.start") == 1 and
          F.seen?(ctx, f, "brce.commit", %{"outcome" => "committed"}),
      evidence: episode_evidence(ep, rows)
    )
  end

  defp execute("SA2A-HOOK-007", f, ctx, runtime, env) do
    subject = subject(env, f)
    hook = F.hook("sa2a-replay-007", "Intrusion", "Alert", subject)
    delta = F.typed_delta("Intrusion", "urn:sa2a:zone:" <> subject)
    replay(f, ctx, runtime, env, subject, hook, delta, delta)
  end

  defp execute("SA2A-HOOK-008", f, ctx, runtime, env) do
    subject = subject(env, f)
    hook = F.hook("sa2a-order-008", "Intrusion", "Alert", subject)
    zone = "urn:sa2a:zone:" <> subject
    ns = F.ns()

    first = """
    @prefix h: <#{ns}> .
    <#{zone}> a h:Intrusion ; h:zone "north" .
    _:w1 h:witnessedBy <#{zone}> ; h:mode h:Armed .
    """

    reordered = """
    @prefix q: <#{ns}> .
    _:other q:mode q:Armed .
    <#{zone}> q:zone "north" .
    _:other q:witnessedBy <#{zone}> .
    <#{zone}> a q:Intrusion .
    """

    replay(f, ctx, runtime, env, subject, hook, first, reordered)
  end

  defp execute("SA2A-HOOK-009", f, ctx, runtime, env) do
    subject = subject(env, f)
    hook = F.hook("sa2a-dup-009", "Intrusion", "Alert", subject)
    delta = F.typed_delta("Intrusion", "urn:sa2a:zone:" <> subject)

    results =
      Context.stimulus(ctx, f, fn ->
        %{admission: admission} = HookReactor.admit([hook], runtime: runtime)

        opts = [
          hooks: [hook],
          delta: delta,
          principal: env.granted,
          bounds: F.bounds!(2, 2, 1)
        ]

        [
          Task.async(fn -> F.run!(runtime, env, admission, opts) end),
          Task.async(fn -> F.run!(runtime, env, admission, opts) end)
        ]
        |> Task.await_many(60_000)
      end)

    rows = F.signals(subject)

    Result.negative(f,
      attempt_observed?:
        F.count(ctx, f, "hook.cascade.start") == 2 and F.count(ctx, f, "brce.claim") == 2 and
          F.seen?(ctx, f, "brce.commit", %{"outcome" => "committed"}),
      forbidden_outcome_observed?: F.count(ctx, f, "brce.actuate.start") >= 2 or length(rows) > 1,
      evidence: %{
        "signal_rows" => length(rows),
        "route_outcomes" =>
          Enum.flat_map(results, fn r -> Enum.map(r.routes, &"#{&1.outcome}:#{&1.code}") end),
        "claims" =>
          ctx |> F.records(f, "brce.claim") |> Enum.map(&to_string(&1.attributes["outcome"]))
      }
    )
  end

  defp execute("SA2A-HOOK-010", f, ctx, runtime, env) do
    subject = subject(env, f)
    sensor = "urn:sa2a:sensor:" <> subject
    hook = F.alarm_hook("sa2a-alarm-010", subject)

    ep =
      Context.stimulus(ctx, f, fn ->
        F.episode(runtime, env,
          hooks: [hook],
          delta: "<#{sensor}> <#{F.ns()}location> <#{F.ns()}Roof> .\n",
          base: F.armed_base(sensor),
          principal: env.granted,
          bounds: F.bounds!(2, 2, 1)
        )
      end)

    rows = F.signals(subject)

    Result.negative(f,
      attempt_observed?: F.seen?(ctx, f, "hook.evaluate", %{"trigger" => "false"}),
      forbidden_outcome_observed?: fired_or_consequence?(ctx, f) or rows != [],
      evidence: episode_evidence(ep, rows)
    )
  end

  defp execute("SA2A-HOOK-011", f, ctx, runtime, env) do
    subject = subject(env, f)
    armed = "urn:sa2a:sensor:armed-" <> subject
    unarmed = "urn:sa2a:sensor:unarmed-" <> subject
    hook = F.alarm_hook("sa2a-alarm-011", subject)

    ep =
      Context.stimulus(ctx, f, fn ->
        F.episode(runtime, env,
          hooks: [hook],
          delta: F.reading_delta(unarmed, 42),
          base: F.armed_base(armed),
          principal: env.granted,
          bounds: F.bounds!(2, 2, 1)
        )
      end)

    rows = F.signals(subject)

    Result.negative(f,
      attempt_observed?:
        F.seen?(ctx, f, "hook.evaluate", %{"trigger" => "true", "guard" => "false"}),
      forbidden_outcome_observed?: fired_or_consequence?(ctx, f) or rows != [],
      evidence: episode_evidence(ep, rows)
    )
  end

  defp execute("SA2A-HOOK-012", f, ctx, runtime, env) do
    subject = subject(env, f)

    hook =
      F.hook("sa2a-planted-012", "Always", "Alert", subject,
        trigger:
          "@prefix h: <#{F.ns()}> .\n<urn:sa2a:planted> a h:Always .\n{ ?s a h:Always } => false .\n"
      )

    ep =
      Context.stimulus(ctx, f, fn ->
        F.episode(runtime, env,
          hooks: [hook],
          delta: F.typed_delta("Unrelated", "urn:sa2a:zone:" <> subject),
          principal: env.granted,
          bounds: F.bounds!(2, 2, 1)
        )
      end)

    rows = F.signals(subject)

    Result.negative(f,
      attempt_observed?: F.seen?(ctx, f, "hook.admission") and F.seen?(ctx, f, "hook.evaluate"),
      forbidden_outcome_observed?:
        F.seen?(ctx, f, "hook.admission", %{"outcome" => "admitted"}) or
          fired_or_consequence?(ctx, f) or rows != [],
      evidence: episode_evidence(ep, rows)
    )
  end

  # --- shared bodies ----------------------------------------------------------

  defp replay(f, ctx, runtime, env, subject, hook, first_delta, second_delta) do
    {first, second} =
      Context.stimulus(ctx, f, fn ->
        %{admission: admission} = HookReactor.admit([hook], runtime: runtime)
        opts = [hooks: [hook], principal: env.granted, bounds: F.bounds!(2, 2, 1)]

        {F.run!(runtime, env, admission, [delta: first_delta] ++ opts),
         F.run!(runtime, env, admission, [delta: second_delta] ++ opts)}
      end)

    rows = F.signals(subject)
    first_ids = Enum.map(first.intents, & &1.intent_id)
    second_ids = Enum.map(second.intents, & &1.intent_id)

    equivalent? =
      first.delta_digest == second.delta_digest and first_ids != [] and
        first_ids == second_ids and generation_one(first) == generation_one(second)

    Result.negative(f,
      attempt_observed?:
        F.count(ctx, f, "hook.cascade.start") == 2 and
          F.count(ctx, f, "hook.intent.constructed") == 2 and
          F.seen?(ctx, f, "brce.commit", %{"outcome" => "committed"}),
      forbidden_outcome_observed?:
        not equivalent? or F.count(ctx, f, "brce.actuate.start") >= 2 or length(rows) > 1 or
          F.seen?(ctx, f, "brce.claim", %{"outcome" => "refused"}),
      evidence: %{
        "delta_digests" => [first.delta_digest, second.delta_digest],
        "intent_ids" => [first_ids, second_ids],
        "verdicts" => [generation_one(first), generation_one(second)],
        "route_outcomes" => [
          Enum.map(first.routes, &to_string(&1.outcome)),
          Enum.map(second.routes, &to_string(&1.outcome))
        ],
        "signal_rows" => length(rows)
      }
    )
  end

  defp generation_one(result) do
    result.evaluations
    |> Enum.filter(&(&1.generation == 1))
    |> Enum.map(&{&1.hook_id, &1.outcome, Map.get(&1, :trigger), Map.get(&1, :guard)})
    |> Enum.map(&Tuple.to_list/1)
  end

  defp fired_or_consequence?(ctx, f) do
    F.seen?(ctx, f, "hook.evaluate", %{"outcome" => "fired"}) or
      F.seen?(ctx, f, "hook.intent.constructed") or F.seen?(ctx, f, "brce.actuate.start") or
      F.seen?(ctx, f, "dispatch.start")
  end

  defp would_match?(runtime, delta_turtle, condition) do
    with {:ok, delta} <- Engine.canonical_delta(delta_turtle),
         {:ok, matched} <- Engine.matches?(runtime, delta.ntriples, condition) do
      matched
    else
      {:error, reason} -> {:unknown, inspect(reason)}
    end
  end

  defp episode_evidence(ep, rows) do
    r = ep.result

    %{
      "cascade_outcome" => r.outcome,
      "cascade_code" => r.code,
      "admission_refusals" => Enum.map(ep.refused, &"#{&1.hook_id}:#{&1.code}"),
      "evaluations" => Enum.map(r.evaluations, &"g#{&1.generation}:#{&1.hook_id}:#{&1.outcome}"),
      "intent_ids" => Enum.map(r.intents, & &1.intent_id),
      "route_outcomes" => Enum.map(r.routes, &"#{&1.outcome}:#{&1.code}"),
      "signal_rows" => length(rows)
    }
  end

  defp subject(env, %Falsifier{id: id}), do: "#{String.downcase(id)}-#{env.nonce}"
end
