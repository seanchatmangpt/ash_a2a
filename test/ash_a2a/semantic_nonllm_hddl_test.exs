defmodule AshA2A.Semantic.NonllmHddlTest do
  @moduledoc """
  Task 4 + 5 of the deterministic (non-LLM) HDDL planning path: real,
  end-to-end coverage of the full non-LLM path -- a caller submitting typed
  goal facts (never free text) all the way through
  `AshA2A.Planning.HddlDeterministicSynthesis.synthesize/3` to a real,
  candidate-only `AshA2A.Semantic.ExecutionPackage`, and back out through
  `ExecutionPackage.to_reply/1` -- with zero LLM/network calls anywhere in
  the trace, proven by inspection of the real collaborators this path calls
  (`AshA2A.Planning.GoalFacts`, `AshA2A.Planning.HddlRenderer`,
  `AshA2A.Planning.HddlSolver`, `AshA2A.Planning.from_envelope/3`,
  `AshA2A.Semantic.ExecutionPackage.new/6`), none of which import or call
  `Req`/`Finch`/`HTTPoison`/`ReqLLM` or any other HTTP client -- confirmed by
  a real `mix xref` / grep pass reported alongside this file's own test
  output, not asserted here as a runtime check (there is no HTTP client
  dependency anywhere in this call graph to intercept).

  Chicago-style throughout: real fixture resource
  (`AshA2A.Test.Fixture.HddlDeterministicFixture`,
  `test/support/fixture.ex`), real compiled capability index, a real OS
  subprocess invocation of the real, CI-built `native/hddl_cli` binary
  (`AshA2A.Planning.HddlSolver.solve/3`), and assertions against the real
  returned/decoded state -- never a call-count or "was this called"
  interaction assertion. This file declares and uses no test double of any
  kind, per this workspace's testing-discipline rule; the real repo-wide
  banned-pattern sweep (expect zero matches over this file) is part of this
  task's own reported verification evidence, not asserted here.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Planning.HddlDeterministicSynthesis
  alias AshA2A.Planning.HddlRenderer
  alias AshA2A.Semantic.ExecutionPackage
  alias AshA2A.Test.Fixture.HddlDeterministicFixture

  @advance_id "AshA2A.Test.Fixture.HddlDeterministicFixture.advance"
  @unlock_id "AshA2A.Test.Fixture.HddlDeterministicFixture.unlock"

  defp base_envelope(overrides \\ %{}) do
    Map.merge(
      %{
        "request_id" => "nonllm-hddl-e2e-#{System.unique_integer([:positive])}",
        "domain_name" => "nonllm-e2e-domain",
        "problem_name" => "nonllm-e2e-problem",
        "objects" => ["on", "off"],
        "init" => [%{"predicate" => "current_phase", "args" => ["on"]}],
        "goal" => [
          %{"predicate" => "current_phase", "args" => ["off"]},
          %{"predicate" => "has_key", "args" => ["off"]}
        ],
        "task_sequence" => [
          %{"capability_id" => @advance_id, "args" => ["on", "off"]},
          %{"capability_id" => @unlock_id, "args" => ["off"]}
        ]
      },
      overrides
    )
  end

  describe "full non-LLM path end to end (positive)" do
    test "a real typed goal-facts envelope synthesizes into a real, solver-verified candidate-only ExecutionPackage" do
      envelope = base_envelope()

      assert {:ok, %ExecutionPackage{} = package} =
               HddlDeterministicSynthesis.synthesize(HddlDeterministicFixture, envelope)

      # Real candidate-only authority ceiling, on every layer of the package
      # -- never an execution/DO standing.
      assert package.standing == :candidate
      assert package.authority == :none
      assert package.semantic_ir.standing == :admitted
      assert package.semantic_ir.authority == :none
      assert package.ontology.authority == :none
      assert package.planning_ir.authority == :none
      assert package.plan_candidate.standing == :candidate
      assert package.plan_candidate.authority == :none

      # The already-admitted capability_ids came from GoalFacts.admit/2 (this
      # test's own submitted task_sequence order), never re-derived from a
      # model's free-text claim -- the direct pass-through the design plan's
      # Task 4 note describes.
      assert package.plan_candidate.capability_ids == [@advance_id, @unlock_id]

      # A real, content-addressed fingerprint (sha256/hex), not a placeholder.
      assert package.fingerprint =~ ~r/^[0-9a-f]{64}$/

      # The package's source is the real HDDL text this path itself rendered
      # and solved -- genuine machine-rendered domain+problem text, not a
      # natural-language string an LLM would have had to interpret.
      assert package.source.media_type == "application/hddl"
      assert package.source.text =~ "(define (domain nonllm-e2e-domain)"
      assert package.source.text =~ "(define (problem nonllm-e2e-problem)"

      synthesis = package.plan_candidate.plan["synthesis"]
      assert synthesis["role"] == "hddl_solver"
      assert synthesis["rationale"] =~ "No LLM call occurred."

      # The embedded "fond" field is the real hddl_cli binary's own stdout
      # JSON -- decode it for real and assert on the real solved-plan shape,
      # not a hand-built stand-in for what a solver "would" return.
      assert {:ok, decoded_plan} = JSON.decode(synthesis["fond"])
      assert decoded_plan["solved"] == true
      refute Map.has_key?(decoded_plan, "error")

      real_actions =
        decoded_plan["policy"]
        |> Enum.map(& &1["action"])
        |> Enum.reject(&String.starts_with?(&1, "htn:decompose:"))

      advance_action_name = HddlRenderer.safe_name(@advance_id)
      unlock_action_name = HddlRenderer.safe_name(@unlock_id)

      assert Enum.any?(real_actions, &(&1 =~ "#{advance_action_name}(on,off)"))
      assert Enum.any?(real_actions, &(&1 =~ "#{unlock_action_name}(off)"))

      # ExecutionPackage.to_reply/1 produces the real A2A reply shape, with
      # the real submitted capability_ids and the real solved hddl/fond text
      # -- the same contract the LLM-driven semantic path returns, satisfied
      # here by a genuinely different, non-LLM producer.
      assert {:reply, [%A2A.Part.Data{} = part]} = ExecutionPackage.to_reply(package)
      assert part.data["standing"] == "candidate"
      assert part.data["authority"] == "none"
      assert part.data["capability_ids"] == [@advance_id, @unlock_id]
      assert part.data["execution_package_fingerprint"] == package.fingerprint
      assert part.data["hddl"] == package.source.text
      assert {:ok, ^decoded_plan} = JSON.decode(part.data["fond"])
    end

    test "additivity regression guard: a real skill declaring no hddl_operator still carries hddl_operators: []" do
      # Proves the additive `hddl_operators` field (Task 1) does not disturb
      # any pre-existing capability that never opted into the deterministic
      # HDDL path -- a real compiled skill from `AshA2A.Test.Fixture.Echo`
      # (no `hddl_operator` block anywhere in its `a2a do ... end`).
      assert {:ok, skill} = AshA2A.Info.skill(AshA2A.Test.Fixture.Echo, "echo")
      assert skill.hddl_operators == []
    end
  end

  describe "negative control: closed capability-id set (proves the grounding check is real, not a no-op)" do
    test "a task_sequence entry naming a capability_id outside the compiled index is refused before any solver subprocess runs" do
      envelope =
        base_envelope(%{
          "task_sequence" => [
            %{"capability_id" => @advance_id, "args" => ["on", "off"]},
            %{
              "capability_id" => "AshA2A.Test.Fixture.HddlDeterministicFixture.teleport",
              "args" => ["off"]
            }
          ]
        })

      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "ash_a2a_nonllm_hddl_negctrl_capability_#{System.unique_integer([:positive])}"
        )

      refute File.exists?(tmp_dir)

      assert {:error,
              %{
                code: :noncanonical_capability,
                detail: "AshA2A.Test.Fixture.HddlDeterministicFixture.teleport"
              }} =
               HddlDeterministicSynthesis.synthesize(HddlDeterministicFixture, envelope,
                 solver_opts: [tmp_dir: tmp_dir]
               )

      # Real proof (not a call-count/interaction assertion) that the real
      # `hddl_cli` subprocess was never invoked for this refused envelope:
      # `HddlSolver.solve/3` always writes its two real temp files under
      # `solver_opts[:tmp_dir]` before shelling out, so a directory that was
      # never even created is real, structural evidence no solver
      # subprocess ran -- the admission fence refused before the pipeline
      # reached `HddlSolver.solve/3` at all.
      refute File.exists?(tmp_dir)
    end

    test "an unrelated resource's real capability id is refused as noncanonical against this fixture's own compiled index" do
      envelope =
        base_envelope(%{
          "task_sequence" => [%{"capability_id" => "AshA2A.Test.Fixture.Echo.echo", "args" => []}]
        })

      assert {:error, %{code: :noncanonical_capability, detail: "AshA2A.Test.Fixture.Echo.echo"}} =
               HddlDeterministicSynthesis.synthesize(HddlDeterministicFixture, envelope)
    end
  end

  describe "negative control: referential and predicate closure" do
    test "a goal fact referencing an undeclared object id is refused" do
      envelope =
        base_envelope(%{
          "goal" => [%{"predicate" => "current_phase", "args" => ["nonexistent-object"]}]
        })

      assert {:error, %{code: :undeclared_object, detail: "nonexistent-object"}} =
               HddlDeterministicSynthesis.synthesize(HddlDeterministicFixture, envelope)
    end

    test "a goal fact using a predicate the domain never declares is refused" do
      envelope =
        base_envelope(%{
          "goal" => [%{"predicate" => "current_phase", "args" => ["off"]}],
          "init" => [
            %{"predicate" => "current_phase", "args" => ["on"]},
            %{"predicate" => "unmodeled_predicate", "args" => ["on"]}
          ]
        })

      assert {:error, %{code: :undeclared_predicate, detail: "unmodeled_predicate"}} =
               HddlDeterministicSynthesis.synthesize(HddlDeterministicFixture, envelope)
    end

    test "an empty task_sequence is refused before any admission logic runs" do
      envelope = base_envelope(%{"task_sequence" => []})

      assert {:error, %{code: :empty_task_sequence}} =
               HddlDeterministicSynthesis.synthesize(HddlDeterministicFixture, envelope)
    end
  end

  describe "negative control: a genuinely unreachable goal (real solver refusal, not a fabricated result)" do
    test "a real unsatisfiable goal is admitted (closed-set checks pass) but the real solver reports it cannot be reached" do
      envelope =
        base_envelope(%{
          # Only :advance is proposed; the real domain's :unlock operator
          # never fires, so has_key(off) is never asserted -- a genuinely
          # unreachable goal from the real solver's point of view, not an
          # admission-fence refusal (every capability id, object, and
          # predicate here is real and declared).
          "task_sequence" => [%{"capability_id" => @advance_id, "args" => ["on", "off"]}]
        })

      assert {:error, %{code: :hddl_solve_error} = decoded} =
               HddlDeterministicSynthesis.synthesize(HddlDeterministicFixture, envelope)

      assert decoded["error"] =~ "NoPlan"
    end
  end
end
