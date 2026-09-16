defmodule AshA2A.Chicago.Courts.Known do
  @moduledoc """
  `CHI-KNOWN` -- Gate 12, Zero Runtime Inference on KNOWN, and Machine
  Experience Regression (RFC-SA2A-002 §43, §134, §22, §100).

      Allocation_LLM(KNOWN) = 0      PlannerInvocations(KNOWN) = 0 (where compiled out)

  Every stimulus drives the real `AshA2A.Planning.RequestRouter`, the real
  `native/hddl_cli` solver, the real `AshA2A.Semantic.Unknown` router over real
  compiled `AshA2A.Semantic.MachineExperience`, and the real generated A2A
  handler (`AshA2A.Agent.__dispatch__/3`) over
  `AshA2A.Chicago.Fixtures.UnknownLlm.Gate`. Model usage is never inferred
  from the absence of a reply: it is read from the SUT's own
  `[:ash_a2a, :llm, :invoke]` (emitted on entry to every inference path),
  planner usage from `[:ash_a2a, :planner, :invoke]`.

  ## Anti-vacuity (§12, §43 last paragraph)

  "Zero tokens" only counts when the reflex positively executed. Negative
  falsifiers key their attempt on the router (or UNKNOWN router) having
  decided AND some machinery having run (solver solved, or inference
  allocated), so a run where nothing executed is `:unknown`, never a kill;
  deleting the guard routes the same request to inference, which the
  forbidden predicate observes (§22). `known_reflex_predicate/0` is exported
  so the court's own test can show a non-executing run never passes and a
  reintroduced inference call is detected as a regression (§134).

  | falsifier | kind | subject |
  |---|---|---|
  | 001 | negative | typed goal_facts reflex allocates no LLM |
  | 002 | negative | compiled phrase-template reflex allocates no LLM |
  | 003 | negative | compiled plan reflex invokes neither LLM nor planner |
  | 004 | positive | N real reflex executions, planner solved, zero LLM |
  | 005 | positive | the same router DOES allocate inference for text with no machinery (instrument live) |
  | 006 | negative | malformed goal_facts + text does not silently regress to inference |
  | 007 | negative | wrapper-nested goal_facts + text does not silently regress to inference |
  | 008 | positive | production A2A handler executes the KNOWN reflex with zero LLM |
  """

  use AshA2A.Chicago.Court

  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Courts.InferenceMappings, as: M
  alias AshA2A.Chicago.Fixtures.UnknownLlm, as: Fx
  alias AshA2A.Planning
  alias AshA2A.Planning.{HddlDeterministicSynthesis, HddlSolver, RequestRouter}
  alias AshA2A.Semantic.{Allocator, MachineExperience, Unknown}
  alias AshA2A.Semantic.Unknown.Resolution

  @court "CHI-KNOWN"

  @llm_allocated {:any,
                  [
                    {:observed, "llm.invoke"},
                    {:observed, "router.tier_selected", %{"tier" => "text"}}
                  ]}

  @router_decided_and_ran {:all,
                           [
                             {:observed, "router.tier_selected"},
                             {:any,
                              [
                                {:observed, "planner.invoke", %{"outcome" => "solved"}},
                                {:observed, "llm.invoke"}
                              ]}
                           ]}

  @router_reached {:any,
                   [{:observed, "router.tier_refused"}, {:observed, "router.tier_selected"}]}

  @known_reflex {:all,
                 [
                   {:observed, "router.tier_selected", %{"tier" => "facts"}},
                   {:observed, "planner.invoke",
                    %{"planner" => "hddl_cli", "outcome" => "solved"}},
                   {:not_observed, "llm.invoke"},
                   {:not_observed, "router.tier_selected", %{"tier" => "text"}}
                 ]}

  @doc "Expected outcome of a positively executed, zero-inference KNOWN reflex."
  def known_reflex_predicate, do: @known_reflex
  @doc "Forbidden outcome on a KNOWN route: inference allocated."
  def llm_allocated_predicate, do: @llm_allocated
  @doc "Attempt evidence: the router decided a tier and machinery ran."
  def router_decided_and_ran_predicate, do: @router_decided_and_ran

  @impl true
  def id, do: @court
  @impl true
  def title, do: "Zero runtime inference on KNOWN / machine-experience regression"
  @impl true
  def gate, do: 12
  @impl true
  def profile, do: :strict
  @impl true
  def rfc_sections, do: ["§43", "§134", "§22", "§100"]

  @impl true
  def ocel_mappings do
    [
      M.llm_invoke(),
      M.planner_invoke(),
      M.router_tier_refused(),
      M.allocation(),
      M.allocator_decision(),
      M.llm_boundary_candidate(),
      M.compile_back(),
      M.register()
    ]
  end

  @impl true
  def falsifiers do
    [
      negative(1,
        invariant:
          "Allocation_LLM(KNOWN) = 0: a typed goal_facts request for a qualified class executes the deterministic reflex without model inference",
        stimulus:
          "RequestRouter.route(Gate, goal_facts message) with the model seams bound to a tripwire model",
        boundary: "AshA2A.Planning.RequestRouter.detect_tier/1 + route/3 facts branch",
        forbidden_outcome: "llm.invoke, or tier :text selected, for a KNOWN typed request",
        attempt_evidence:
          "router.tier_selected AND (planner.invoke solved OR llm.invoke): the router decided and machinery ran",
        survival_evidence:
          "llm.invoke / router.tier_selected{tier=text} attributed to the stimulus",
        guard:
          "RequestRouter.detect_tier/1 {:facts, envelope} clause routing to HddlDeterministicSynthesis, never Compiler.compile_source/3",
        attempt_predicate: @router_decided_and_ran,
        outcome_predicate: @llm_allocated
      ),
      negative(2,
        invariant:
          "a KNOWN phrase compiled into an admitted template executes the reflex without model inference",
        stimulus:
          "RequestRouter.route(Gate, known phrase text, phrase_templates: [compiled gate template]) with tripwire model seams",
        boundary: "AshA2A.Planning.RequestRouter.route_text/3 (PhraseParser before Compiler)",
        forbidden_outcome: "llm.invoke or tier :text for a phrase the admitted template covers",
        attempt_evidence: "router.tier_selected AND (planner.invoke solved OR llm.invoke)",
        survival_evidence:
          "llm.invoke / router.tier_selected{tier=text} attributed to the stimulus",
        guard: "RequestRouter.route_text/3 PhraseParser.parse/2 {:ok, envelope} branch",
        attempt_predicate: @router_decided_and_ran,
        outcome_predicate: @llm_allocated
      ),
      negative(3,
        invariant:
          "PlannerInvocations(KNOWN) = 0 where the planner was compiled out: a compiled plan reflex needs neither planner nor model",
        stimulus:
          "Unknown.route(class, preserved subject, machinery: compiled :plan store, budget, resolver: tripwire) then Planning.from_envelope of the returned plan",
        boundary:
          "AshA2A.Semantic.Unknown.route/3 step 1 (MachineExperience.resolve/3 before any resolver)",
        forbidden_outcome:
          "semantic.allocation{resolver=llm}, planner.invoke or llm.invoke under the stimulus",
        attempt_evidence: "semantic.allocation emitted by the UNKNOWN router (any resolver)",
        survival_evidence: "semantic.allocation{resolver=llm} / planner.invoke / llm.invoke",
        guard: "Unknown.route/3 consulting MachineExperience.resolve/3 before resolve_declared/3",
        attempt_predicate: {:observed, "semantic.allocation"},
        outcome_predicate:
          {:any,
           [
             {:observed, "semantic.allocation", %{"resolver" => "llm"}},
             {:observed, "planner.invoke"},
             {:observed, "llm.invoke"}
           ]}
      ),
      Falsifier.new!(
        id: "CHI-KNOWN-004",
        court_id: @court,
        kind: :positive_control,
        invariant:
          "§43 positive execution: the KNOWN reflex really executes (router facts/phrase tiers, solver solved, candidate package) with zero model allocation",
        stimulus:
          "three KNOWN requests (goal_facts, compiled phrase, goal_facts) through RequestRouter.route/3",
        boundary: "RequestRouter + HddlSolver + ExecutionPackage",
        attempt_evidence: "router.tier_selected",
        survival_evidence:
          "tier facts and tier phrase selected, planner.invoke{hddl_cli,solved}, no llm.invoke; three candidate packages",
        attempt_predicate: {:observed, "router.tier_selected"},
        outcome_predicate:
          {:all, [@known_reflex, {:observed, "router.tier_selected", %{"tier" => "phrase"}}]}
      ),
      Falsifier.new!(
        id: "CHI-KNOWN-005",
        court_id: @court,
        kind: :positive_control,
        invariant:
          "§100 discrimination: the inference instrument is live -- text with no compiled machinery does allocate the model",
        stimulus: "RequestRouter.route(Gate, known phrase text) with NO phrase templates",
        boundary: "RequestRouter.route_text/3 -> Compiler.compile_source/3",
        attempt_evidence: "router.tier_selected",
        survival_evidence:
          "router.tier_selected{tier=text} and llm.invoke{site=semantic_compiler}",
        attempt_predicate: {:observed, "router.tier_selected"},
        outcome_predicate:
          {:all,
           [
             {:observed, "router.tier_selected", %{"tier" => "text"}},
             {:observed, "llm.invoke", %{"site" => "semantic_compiler"}}
           ]}
      ),
      negative(6,
        invariant:
          "§134: a malformed KNOWN typed request fails closed; it never silently regresses to general inference",
        stimulus:
          "RequestRouter.route of a message with goal_facts: \"not an object\" plus real KNOWN-phrase text",
        boundary: "RequestRouter.detect_tier/1 :invalid_goal_facts clause",
        forbidden_outcome: "llm.invoke or tier :text",
        attempt_evidence: "router.tier_refused or router.tier_selected (the router decided)",
        survival_evidence: "llm.invoke / router.tier_selected{tier=text}",
        guard: "RequestRouter.detect_tier/1 {:ok, _not_a_map} -> :invalid_goal_facts",
        attempt_predicate: @router_reached,
        outcome_predicate: @llm_allocated
      ),
      negative(7,
        invariant:
          "§134: goal_facts nested under a wrapper key beside text never silently regresses to inference",
        stimulus:
          "RequestRouter.route of a message with {\"payload\" => {\"goal_facts\" => envelope}} plus KNOWN-phrase text",
        boundary: "RequestRouter.detect_tier/1 nested-shape scan",
        forbidden_outcome: "llm.invoke or tier :text",
        attempt_evidence: "router.tier_refused or router.tier_selected",
        survival_evidence: "llm.invoke / router.tier_selected{tier=text}",
        guard:
          "RequestRouter.detect_tier/1 nested_goal_facts_key?/1 -> :ambiguous_goal_facts_shape",
        attempt_predicate: @router_reached,
        outcome_predicate: @llm_allocated
      ),
      Falsifier.new!(
        id: "CHI-KNOWN-008",
        court_id: @court,
        kind: :positive_control,
        invariant:
          "the production A2A semantic surface executes the KNOWN reflex with zero model allocation",
        stimulus: "AshA2A.Agent.__dispatch__(Gate, semantic_request goal_facts message, %{})",
        boundary: "AshA2A.Agent dispatch_semantic_route/2 -> RequestRouter facts tier",
        attempt_evidence: "router.tier_selected",
        survival_evidence:
          "tier facts, planner.invoke solved, no llm.invoke; reply carries a candidate package",
        attempt_predicate: {:observed, "router.tier_selected"},
        outcome_predicate: @known_reflex
      )
    ]
  end

  defp negative(n, fields) do
    Falsifier.new!(
      [
        id: "CHI-KNOWN-" <> String.pad_leading(Integer.to_string(n), 3, "0"),
        court_id: @court,
        kind: :negative,
        failure_class: :planning_failure,
        rfc_sections: ["§43", "§134"]
      ] ++ fields
    )
  end

  @impl true
  def run(%Context{} = ctx) do
    [f1, f2, f3, f4, f5, f6, f7, f8] = falsifiers()

    if File.exists?(HddlSolver.cli_path()) do
      [
        facts_reflex(ctx, f1),
        phrase_reflex(ctx, f2),
        compiled_plan_reflex(ctx, f3),
        repeated_reflex(ctx, f4),
        instrument_live(ctx, f5),
        no_silent_regression(ctx, f6, invalid_facts_message()),
        no_silent_regression(ctx, f7, nested_facts_message()),
        agent_reflex(ctx, f8)
      ]
    else
      detail = "hddl_cli not built at #{HddlSolver.cli_path()}; the KNOWN reflex cannot execute"

      [
        Result.blocked(f1, detail),
        Result.blocked(f2, detail),
        Result.blocked(f3, detail),
        Result.blocked(f4, detail),
        instrument_live(ctx, f5),
        no_silent_regression(ctx, f6, invalid_facts_message()),
        no_silent_regression(ctx, f7, nested_facts_message()),
        Result.blocked(f8, detail)
      ]
    end
  end

  defp tripwires,
    do: [generate_object: Fx.tripwire_model(), plan_generate_object: Fx.tripwire_model()]

  defp facts_reflex(ctx, f) do
    envelope = Fx.goal_facts("chicago-known-001-#{Fx.unique()}")

    reply =
      Context.stimulus(ctx, f, fn ->
        M.guarded(fn ->
          RequestRouter.route(Fx.gate(), Fx.facts_message(envelope), tripwires())
        end)
      end)

    negative_result(ctx, f, reply)
  end

  defp phrase_reflex(ctx, f) do
    reply =
      Context.stimulus(ctx, f, fn ->
        M.guarded(fn ->
          RequestRouter.route(
            Fx.gate(),
            Fx.text_message(Fx.known_phrase()),
            [phrase_templates: [Fx.gate_phrase_template()]] ++ tripwires()
          )
        end)
      end)

    negative_result(ctx, f, reply)
  end

  defp negative_result(ctx, f, reply) do
    Result.negative(f,
      attempt_observed?:
        M.seen?(ctx, f, "router.tier_selected") and
          (M.seen?(ctx, f, "planner.invoke", %{"outcome" => "solved"}) or
             M.seen?(ctx, f, "llm.invoke")),
      forbidden_outcome_observed?:
        M.seen?(ctx, f, "llm.invoke") or
          M.seen?(ctx, f, "router.tier_selected", %{"tier" => "text"}),
      evidence: %{"reply" => summarize(reply)}
    )
  end

  # The plan is solved ONCE by the real planner at compile time (outside the
  # stimulus), compiled into :plan machinery via the real boundary chain
  # (Unknown.route :prover -> LlmBoundary candidate -> compile_back ->
  # register), then the preserved subject reruns through the compiled route.
  defp compiled_plan_reflex(ctx, f) do
    class = "chicago.known.gate_cycle.#{Fx.unique()}"
    subject = %{"cycle" => "gate", "from" => "on", "to" => "off"}

    with {:ok, package} <-
           HddlDeterministicSynthesis.synthesize(
             Fx.gate(),
             Fx.goal_facts("chicago-known-003-#{Fx.unique()}")
           ),
         plan = package.plan_candidate.plan,
         {:ok, budget} <- Allocator.new([compute_units: 1], issued_by: {:host, :chicago_known}),
         {:ok, :resolved, %Resolution{} = resolution, _} <-
           Unknown.route(class, subject,
             budget: budget,
             resolver:
               {:prover,
                fn _unknown ->
                  {:ok, %{"plan_fingerprint" => package.plan_candidate.fingerprint}}
                end}
           ),
         {:ok, machinery} <-
           MachineExperience.compile_back(resolution, :plan, fn
             ^subject -> {:ok, plan}
             _other -> :no_match
           end),
         {:ok, store, _changelog} <-
           MachineExperience.register(MachineExperience.new_store(), machinery) do
      reply =
        Context.stimulus(ctx, f, fn ->
          M.guarded(fn ->
            {:ok, rerun_budget} =
              Allocator.new([inference_calls: 1], issued_by: {:host, :chicago_known})

            case Unknown.route(class, subject,
                   machinery: store,
                   budget: rerun_budget,
                   resolver: {:llm, fn _unknown -> {:error, "chicago tripwire resolver"} end}
                 ) do
              {:ok, :machinery, compiled_plan, _budget} ->
                Planning.from_envelope(Fx.gate(), compiled_plan,
                  planner: :compiled_reflex,
                  formalism: :hddl
                )

              other ->
                other
            end
          end)
        end)

      executed? =
        match?({:ok, %Planning.Candidate{standing: :candidate, authority: :none}}, reply)

      forbidden? =
        M.seen?(ctx, f, "semantic.allocation", %{"resolver" => "llm"}) or
          M.seen?(ctx, f, "planner.invoke") or M.seen?(ctx, f, "llm.invoke")

      # Zero spend only counts when the compiled reflex positively executed.
      Result.negative(f,
        attempt_observed?: M.seen?(ctx, f, "semantic.allocation") and (executed? or forbidden?),
        forbidden_outcome_observed?: forbidden?,
        evidence: %{"reply" => summarize(reply), "compiled_reflex_executed" => executed?}
      )
    else
      other -> Result.unknown(f, "could not compile the plan reflex: #{inspect(other, limit: 8)}")
    end
  end

  defp repeated_reflex(ctx, f) do
    replies =
      Context.stimulus(ctx, f, fn ->
        for message <- [
              Fx.facts_message(Fx.goal_facts("chicago-known-004a-#{Fx.unique()}")),
              Fx.text_message(Fx.known_phrase()),
              Fx.facts_message(Fx.goal_facts("chicago-known-004b-#{Fx.unique()}"))
            ] do
          M.guarded(fn ->
            RequestRouter.route(
              Fx.gate(),
              message,
              [phrase_templates: [Fx.gate_phrase_template()]] ++ tripwires()
            )
          end)
        end
      end)

    packages = Enum.count(replies, &match?({:ok, %{standing: :candidate, authority: :none}}, &1))
    solved = M.count(ctx, f, "planner.invoke", %{"planner" => "hddl_cli", "outcome" => "solved"})
    llm = M.count(ctx, f, "llm.invoke")

    Result.positive(f,
      attempt_observed?: M.seen?(ctx, f, "router.tier_selected"),
      expected_outcome_observed?: packages == 3 and solved >= 3 and llm == 0,
      evidence: %{
        "executions" => 3,
        "candidate_packages" => packages,
        "planner_invocations_solved" => solved,
        "allocation_llm" => llm
      }
    )
  end

  defp instrument_live(ctx, f) do
    reply =
      Context.stimulus(ctx, f, fn ->
        M.guarded(fn ->
          RequestRouter.route(Fx.gate(), Fx.text_message(Fx.known_phrase()), tripwires())
        end)
      end)

    Result.positive(f,
      attempt_observed?: M.seen?(ctx, f, "router.tier_selected"),
      expected_outcome_observed?:
        M.seen?(ctx, f, "router.tier_selected", %{"tier" => "text"}) and
          M.seen?(ctx, f, "llm.invoke", %{"site" => "semantic_compiler"}),
      evidence: %{"reply" => summarize(reply)}
    )
  end

  defp no_silent_regression(ctx, f, message) do
    reply =
      Context.stimulus(ctx, f, fn ->
        M.guarded(fn -> RequestRouter.route(Fx.gate(), message, tripwires()) end)
      end)

    Result.negative(f,
      attempt_observed?:
        M.seen?(ctx, f, "router.tier_refused") or M.seen?(ctx, f, "router.tier_selected"),
      forbidden_outcome_observed?:
        M.seen?(ctx, f, "llm.invoke") or
          M.seen?(ctx, f, "router.tier_selected", %{"tier" => "text"}),
      evidence: %{"reply" => summarize(reply)}
    )
  end

  defp agent_reflex(ctx, f) do
    message =
      Fx.facts_message(Fx.goal_facts("chicago-known-008-#{Fx.unique()}"), %{
        "semantic_request" => true
      })

    reply =
      Context.stimulus(ctx, f, fn ->
        M.guarded(fn -> AshA2A.Agent.__dispatch__(Fx.gate(), message, %{}) end)
      end)

    candidate_reply? =
      case reply do
        {:reply, [%A2A.Part.Data{data: %{"standing" => "candidate", "authority" => "none"}} | _]} ->
          true

        _ ->
          false
      end

    Result.positive(f,
      attempt_observed?: M.seen?(ctx, f, "router.tier_selected"),
      expected_outcome_observed?:
        candidate_reply? and M.seen?(ctx, f, "router.tier_selected", %{"tier" => "facts"}) and
          M.seen?(ctx, f, "planner.invoke", %{"outcome" => "solved"}) and
          not M.seen?(ctx, f, "llm.invoke"),
      evidence: %{"candidate_reply" => candidate_reply?, "reply" => summarize(reply)}
    )
  end

  defp invalid_facts_message do
    A2A.Message.new_user([
      A2A.Part.Data.new(%{"goal_facts" => "not an object"}),
      A2A.Part.Text.new(Fx.known_phrase())
    ])
  end

  defp nested_facts_message do
    A2A.Message.new_user([
      A2A.Part.Data.new(%{
        "payload" => %{"goal_facts" => Fx.goal_facts("chicago-known-007-#{Fx.unique()}")}
      }),
      A2A.Part.Text.new(Fx.known_phrase())
    ])
  end

  @doc false
  def summarize({:ok, %{__struct__: struct} = value}),
    do: "ok " <> inspect(struct) <> " " <> to_string(Map.get(value, :standing))

  def summarize({tag, %{} = map}) when tag in [:error, :unknown],
    do: "#{tag} " <> inspect(Map.get(map, :code) || map, limit: 5)

  def summarize(other), do: inspect(other, limit: 5, printable_limit: 200)
end
