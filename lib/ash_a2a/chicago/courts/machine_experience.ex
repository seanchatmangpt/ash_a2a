defmodule AshA2A.Chicago.Courts.MachineExperience do
  @moduledoc """
  `SA2A-MX` -- Machine Experience Qualification (RFC-SA2A-002 §82, §134).

      ∂I_required / ∂MachineExperience < 0

  A preserved fixture of one semantic class ("cycle the gate from on to off")
  is first genuinely UNKNOWN: the real `AshA2A.Semantic.Unknown` router spends
  an LLM allocation and the real `AshA2A.Semantic.LlmBoundary` returns a
  candidate. The court derives a deterministic generator from that candidate
  and compiles it back through the real
  `AshA2A.Semantic.MachineExperience.compile_back/4` + `register/2`. The same
  fixture then reruns through the compiled route -- `Unknown.route/3` step 1,
  then the real `RequestRouter` facts tier and the real `hddl_cli` solver --
  and must execute with zero exploratory inference.

  | falsifier | kind | subject |
  |---|---|---|
  | 001 | positive | UNKNOWN resolution (1 LLM allocation) compiles into registered machinery |
  | 002 | negative | the preserved fixture rerun through the compiled route allocates no inference |
  | 003 | positive | repeated reruns execute a real solved candidate plan with Allocation_LLM = 0 |
  | 004 | negative | compiled machinery does not over-generalize past its class coverage |
  | 005 | negative | compile-back refuses anything that is not a boundary-issued candidate |
  """

  use AshA2A.Chicago.Court

  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Courts.InferenceMappings, as: M
  alias AshA2A.Chicago.Courts.Known
  alias AshA2A.Chicago.Fixtures.UnknownLlm, as: Fx
  alias AshA2A.Planning.{HddlSolver, RequestRouter}
  alias AshA2A.Semantic.{Allocator, ExecutionPackage, MachineExperience, Unknown}
  alias AshA2A.Semantic.Unknown.Resolution

  @court "SA2A-MX"
  @preserved_fixture "cycle the gate from on to off"
  @uncovered_subject "cycle the gate twice before noon"

  @inference_spent {:any,
                    [
                      {:observed, "semantic.allocation", %{"resolver" => "llm"}},
                      {:observed, "llm.invoke"},
                      {:observed, "llm_boundary.candidate"}
                    ]}

  @doc "The preserved fixture of the solved semantic class."
  def preserved_fixture, do: @preserved_fixture

  @impl true
  def id, do: @court
  @impl true
  def title, do: "Machine experience: resolved UNKNOWN compiles into reusable admitted machinery"
  @impl true
  def gate, do: nil
  @impl true
  def profile, do: :strict
  @impl true
  def rfc_sections, do: ["§82", "§134", "§100"]

  @impl true
  def ocel_mappings do
    [
      M.allocation(),
      M.allocator_decision(),
      M.llm_boundary_candidate(),
      M.compile_back(),
      M.register(),
      M.llm_invoke(),
      M.planner_invoke()
    ]
  end

  @impl true
  def falsifiers do
    [
      Falsifier.new!(
        id: "SA2A-MX-001",
        court_id: @court,
        kind: :positive_control,
        invariant:
          "§82: a successful UNKNOWN resolution compiles into reusable admitted machinery (a generator)",
        stimulus:
          "Unknown.route(preserved fixture) with an LLM resolver; compile_back/4 of the candidate as :generator; register/2",
        boundary:
          "Unknown.route/3 -> LlmBoundary.candidate/3 -> MachineExperience.compile_back/4 + register/2",
        attempt_evidence: "semantic.allocation{resolver=llm}",
        survival_evidence:
          "llm_boundary.candidate{candidate} precedes machine_experience.compile_back{compiled} for the class; register{added=true}",
        attempt_predicate: {:observed, "semantic.allocation", %{"resolver" => "llm"}},
        outcome_predicate:
          {:all,
           [
             {:observed, "llm_boundary.candidate", %{"outcome" => "candidate"}},
             {:observed, "machine_experience.compile_back", %{"outcome" => "compiled"}},
             {:precedes, "llm_boundary.candidate", "machine_experience.compile_back",
              "semantic_class"},
             {:observed, "machine_experience.register", %{"added" => "true"}}
           ]}
      ),
      negative(2,
        invariant:
          "§82/§134: once compiled, the preserved fixture reruns through the compiled route with zero exploratory inference",
        stimulus:
          "Unknown.route(preserved fixture, machinery: compiled store, budget, LLM resolver) then RequestRouter.route of the generated goal_facts",
        boundary: "Unknown.route/3 step 1 (MachineExperience.resolve/3 before resolver dispatch)",
        forbidden_outcome:
          "semantic.allocation{resolver=llm}, llm_boundary.candidate or llm.invoke under the rerun",
        attempt_evidence: "semantic.allocation (any resolver) for the rerun",
        survival_evidence: "any exploratory inference attributed to the rerun",
        guard: "Unknown.route/3 consulting MachineExperience.resolve/3 before resolve_declared/3",
        attempt_predicate: {:observed, "semantic.allocation"},
        outcome_predicate: @inference_spent
      ),
      Falsifier.new!(
        id: "SA2A-MX-003",
        court_id: @court,
        kind: :positive_control,
        invariant:
          "§82 benchmark: reruns of the solved class execute a real solved candidate plan with Allocation_LLM = 0 (was 1 before compile-back)",
        stimulus: "three reruns of the preserved fixture through the compiled route",
        boundary: "Unknown.route/3 + RequestRouter facts tier + HddlSolver",
        attempt_evidence: "semantic.allocation{resolver=machinery}",
        survival_evidence:
          "router tier facts, planner.invoke solved, no llm.invoke / llm allocation / boundary candidate",
        attempt_predicate: {:observed, "semantic.allocation", %{"resolver" => "machinery"}},
        outcome_predicate:
          {:all,
           [
             {:observed, "router.tier_selected", %{"tier" => "facts"}},
             {:observed, "planner.invoke", %{"planner" => "hddl_cli", "outcome" => "solved"}},
             {:not, @inference_spent}
           ]}
      ),
      negative(4,
        invariant:
          "compiled machinery covers only its class: an uncovered subject returns to UNKNOWN, never a machinery hit",
        stimulus:
          "Unknown.route(class, uncovered subject, machinery: compiled store, budget, LLM resolver)",
        boundary: "MachineExperience.resolve/3",
        forbidden_outcome: "semantic.allocation{resolver=machinery} for the uncovered subject",
        attempt_evidence: "semantic.allocation (any resolver)",
        survival_evidence: "a machinery hit for a subject the generator does not match",
        guard: "MachineExperience.resolve/3 safe_apply/2 accepting only {:ok, result}",
        attempt_predicate: {:observed, "semantic.allocation"},
        outcome_predicate: {:observed, "semantic.allocation", %{"resolver" => "machinery"}}
      ),
      negative(5,
        invariant:
          "only a boundary-issued candidate compiles back: a resolution claiming standing/authority is refused (no self-promoted rule)",
        stimulus:
          "compile_back/4 of the MX-001 resolution with standing :admitted / authority forged, and of a bare model map",
        boundary: "MachineExperience.compile_back/4",
        forbidden_outcome: "machine_experience.compile_back{outcome=compiled}",
        attempt_evidence: "machine_experience.compile_back decision (any outcome)",
        survival_evidence: "compiled machinery from a non-candidate",
        guard:
          "compile_back/4 first clause requiring %Resolution{standing: :candidate, authority: :none}",
        attempt_predicate: {:observed, "machine_experience.compile_back"},
        outcome_predicate:
          {:observed, "machine_experience.compile_back", %{"outcome" => "compiled"}}
      )
    ]
  end

  defp negative(n, fields) do
    Falsifier.new!(
      [
        id: "SA2A-MX-" <> String.pad_leading(Integer.to_string(n), 3, "0"),
        court_id: @court,
        kind: :negative,
        failure_class: :planning_failure,
        rfc_sections: ["§82", "§134"]
      ] ++ fields
    )
  end

  @impl true
  def run(%Context{} = ctx) do
    [f1, f2, f3, f4, f5] = falsifiers()
    class = "chicago.mx.gate_cycle.#{Fx.unique()}"

    {r1, compiled} = resolve_and_compile(ctx, f1, class)

    case compiled do
      {:ok, store, resolution} ->
        solver? = File.exists?(HddlSolver.cli_path())

        [
          r1,
          if(solver?, do: rerun(ctx, f2, class, store), else: blocked(f2)),
          if(solver?, do: reruns(ctx, f3, class, store), else: blocked(f3)),
          uncovered(ctx, f4, class, store),
          forged(ctx, f5, resolution)
        ]

      other ->
        detail = "compile-back produced no machinery: #{inspect(other, limit: 6)}"
        [r1 | Enum.map([f2, f3, f4, f5], &Result.unknown(&1, detail))]
    end
  end

  defp blocked(f), do: Result.blocked(f, "hddl_cli not built at #{HddlSolver.cli_path()}")

  defp budget, do: Allocator.new!([inference_calls: 1], issued_by: {:host, :chicago_mx})

  # The discovery engine: a real resolver function returning the model-shaped
  # proposal for the class (see AshA2A.Chicago.Fixtures.UnknownLlm moduledoc).
  defp model_resolver do
    {:llm,
     fn _unknown ->
       {:ok,
        %{
          "template" => "^cycle the gate from (?<from>[a-z]+) to (?<to>[a-z]+)$",
          "capability_ids" => Fx.gate_capabilities()
        }}
     end}
  end

  # The caller-derived deterministic generator (MachineExperience keeps the
  # promotion decision outside the model): the proposed template is compiled
  # and its capability ids re-checked against the canonical gate capabilities.
  defp derive_generator(%Resolution{payload: payload}) do
    with {:ok, regex} <- Regex.compile(payload["template"]),
         true <- payload["capability_ids"] == Fx.gate_capabilities() do
      {:ok,
       fn
         subject when is_binary(subject) ->
           case Regex.named_captures(regex, subject) do
             %{"from" => from, "to" => to} ->
               {:ok, Fx.goal_facts("chicago-mx-#{Fx.unique()}", from, to)}

             nil ->
               :no_match
           end

         _other ->
           :no_match
       end}
    else
      _ -> {:error, "candidate did not yield a deterministic generator"}
    end
  end

  defp resolve_and_compile(ctx, f, class) do
    compiled =
      Context.stimulus(ctx, f, fn ->
        M.guarded(fn ->
          with {:ok, :resolved, %Resolution{} = resolution, _} <-
                 Unknown.route(class, @preserved_fixture,
                   budget: budget(),
                   resolver: model_resolver()
                 ),
               {:ok, generator} <- derive_generator(resolution),
               {:ok, machinery} <-
                 MachineExperience.compile_back(resolution, :generator, generator),
               {:ok, store, changelog} <-
                 MachineExperience.register(MachineExperience.new_store(), machinery) do
            if class in changelog.added,
              do: {:ok, store, resolution},
              else: {:not_added, changelog}
          end
        end)
      end)

    result =
      Result.positive(f,
        attempt_observed?: M.seen?(ctx, f, "semantic.allocation", %{"resolver" => "llm"}),
        expected_outcome_observed?:
          match?({:ok, _, _}, compiled) and
            M.seen?(ctx, f, "machine_experience.compile_back", %{"outcome" => "compiled"}) and
            M.seen?(ctx, f, "machine_experience.register", %{"added" => "true"}),
        evidence: %{
          "allocation_llm_before_compile_back" =>
            M.count(ctx, f, "semantic.allocation", %{"resolver" => "llm"})
        }
      )

    {result, compiled}
  end

  defp rerun_once(class, store) do
    M.guarded(fn ->
      case Unknown.route(class, @preserved_fixture,
             machinery: store,
             budget: budget(),
             resolver: model_resolver()
           ) do
        {:ok, :machinery, envelope, _} ->
          RequestRouter.route(Fx.gate(), Fx.facts_message(envelope),
            generate_object: Fx.tripwire_model(),
            plan_generate_object: Fx.tripwire_model()
          )

        other ->
          other
      end
    end)
  end

  defp executed?(reply),
    do: match?({:ok, %ExecutionPackage{standing: :candidate, authority: :none}}, reply)

  defp inference_seen?(ctx, f) do
    M.seen?(ctx, f, "semantic.allocation", %{"resolver" => "llm"}) or
      M.seen?(ctx, f, "llm.invoke") or M.seen?(ctx, f, "llm_boundary.candidate")
  end

  defp rerun(ctx, f, class, store) do
    reply = Context.stimulus(ctx, f, fn -> rerun_once(class, store) end)
    forbidden? = inference_seen?(ctx, f)

    Result.negative(f,
      attempt_observed?:
        M.seen?(ctx, f, "semantic.allocation") and (executed?(reply) or forbidden?),
      forbidden_outcome_observed?: forbidden?,
      evidence: %{"reply" => Known.summarize(reply)}
    )
  end

  defp reruns(ctx, f, class, store) do
    replies = Context.stimulus(ctx, f, fn -> for _ <- 1..3, do: rerun_once(class, store) end)
    executed = Enum.count(replies, &executed?/1)
    machinery = M.count(ctx, f, "semantic.allocation", %{"resolver" => "machinery"})

    llm =
      M.count(ctx, f, "semantic.allocation", %{"resolver" => "llm"}) +
        M.count(ctx, f, "llm.invoke")

    Result.positive(f,
      attempt_observed?: machinery > 0,
      expected_outcome_observed?:
        executed == 3 and machinery >= 3 and llm == 0 and not inference_seen?(ctx, f),
      evidence: %{
        "reruns" => 3,
        "executed_candidate_plans" => executed,
        "allocation_machinery" => machinery,
        "allocation_llm_after_compile_back" => llm
      }
    )
  end

  defp uncovered(ctx, f, class, store) do
    reply =
      Context.stimulus(ctx, f, fn ->
        M.guarded(fn ->
          Unknown.route(class, @uncovered_subject,
            machinery: store,
            budget: budget(),
            resolver: model_resolver()
          )
        end)
      end)

    Result.negative(f,
      attempt_observed?: M.seen?(ctx, f, "semantic.allocation"),
      forbidden_outcome_observed?:
        match?({:ok, :machinery, _, _}, reply) or
          M.seen?(ctx, f, "semantic.allocation", %{"resolver" => "machinery"}),
      evidence: %{"reply" => Known.summarize(reply)}
    )
  end

  defp forged(ctx, f, %Resolution{} = resolution) do
    generator = fn _subject -> {:ok, :forged} end

    replies =
      Context.stimulus(ctx, f, fn ->
        [
          MachineExperience.compile_back(%{resolution | standing: :admitted}, :rule, generator),
          MachineExperience.compile_back(%{resolution | authority: :granted}, :rule, generator),
          MachineExperience.compile_back(
            %{"class" => resolution.class, "standing" => "admitted", "rule" => "always true"},
            :rule,
            generator
          )
        ]
      end)

    Result.negative(f,
      attempt_observed?: M.count(ctx, f, "machine_experience.compile_back") >= 3,
      forbidden_outcome_observed?:
        Enum.any?(replies, &match?({:ok, _}, &1)) or
          M.seen?(ctx, f, "machine_experience.compile_back", %{"outcome" => "compiled"}),
      evidence: %{"replies" => Enum.map(replies, &Known.summarize/1)}
    )
  end
end
