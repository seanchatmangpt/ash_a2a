# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT

# ==============================================================================
# Consolidated Test Suite: Direct ash_a2a Suite: Semantic Compiler IR
# Target File 1 of Worker 09
# Consolidated from 14 source files:
#   - test/ash_a2a/semantic_capability_composition_test.exs
#   - test/ash_a2a/semantic_compiler_bounds_test.exs
#   - test/ash_a2a/semantic_compiler_hddl_solver_verification_test.exs
#   - test/ash_a2a/semantic_compiler_test.exs
#   - test/ash_a2a/semantic_conformance_dynamic_call_sites_test.exs
#   - test/ash_a2a/semantic_construct_test.exs
#   - test/ash_a2a/semantic_envelope_doctest_test.exs
#   - test/ash_a2a/semantic_envelope_test.exs
#   - test/ash_a2a/semantic_evidence_ref_test.exs
#   - test/ash_a2a/semantic_execution_package_test.exs
#   - test/ash_a2a/semantic_falsifier_s18_4_test.exs
#   - test/ash_a2a/semantic_feedback_test.exs
#   - test/ash_a2a/semantic_graph_law_replay_token_test.exs
#   - test/ash_a2a/semantic_ir_test.exs
# ==============================================================================

# --- SECTION 1: Original test/ash_a2a/semantic_capability_composition_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.CapabilityCompositionTest do
  @moduledoc """
  RFC-SA2A-001 S48: capabilities compose when `Effects(c1)` entails
  `Preconditions(c2)`, and authority requirements remain INDEPENDENT --
  composing two capabilities MUST NOT raise either participant's authority
  ceiling.

  All state-based: real STRIPS transforms over real fact sets, real returned
  structs, real refusal tuples.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{CapabilityComposition, CapabilityProfile, Composition}

  # `advance` mirrors the real `test/support/hddl/freedom_gym_meeting/domain.hddl`
  # action: precondition `(current-phase ?from)`, effect
  # `(and (not (current-phase ?from)) (current-phase ?to))`.
  defp advance(from, to, opts \\ []) do
    %CapabilityProfile{
      capability_id: Keyword.get(opts, :id, "advance:#{from}->#{to}"),
      consequence: Keyword.get(opts, :consequence, :change),
      preconditions: [{:"current-phase", [from]}],
      add_effects: [{:"current-phase", [to]}],
      delete_effects: [{:"current-phase", [from]}],
      authority_requirement: Keyword.get(opts, :authority_requirement, %{})
    }
  end

  describe "S48 -- Effects(c1) entails Preconditions(c2)" do
    test "composes when c1's effects alone establish c2's preconditions" do
      c1 = advance(:open, :"trust-god")
      c2 = advance(:"trust-god", :"clean-house")

      assert {:ok, %Composition{} = composition} = CapabilityComposition.compose(c1, c2)

      assert composition.left == "advance:open->trust-god"
      assert composition.right == "advance:trust-god->clean-house"
      assert composition.resulting_state == [{"current-phase", ["clean-house"]}]
      assert composition.standing == :candidate
      assert composition.authority == :none
      assert composition.composition_digest =~ ~r/\Asha256:[0-9a-f]{64}\z/
    end

    test "refuses when c1's effects do not establish c2's preconditions, naming the unmet facts" do
      c1 = advance(:open, :"trust-god")
      c2 = advance(:fellowship, :close)

      assert {:error, %{code: :composition_preconditions_unmet, detail: detail}} =
               CapabilityComposition.compose(c1, c2)

      assert detail.unmet == [{"current-phase", ["fellowship"]}]
      assert detail.resulting_state == [{"current-phase", ["trust-god"]}]
      assert detail.left == "advance:open->trust-god"
      assert detail.right == "advance:fellowship->close"
    end

    test "delete effects are honored after adds -- a self-deleting effect does not satisfy c2" do
      # c1 adds `(ready)` and then deletes it. Its net effect establishes
      # nothing, so a c2 requiring `(ready)` must NOT compose.
      c1 = %CapabilityProfile{
        capability_id: "adds-then-deletes",
        preconditions: [],
        add_effects: [{:ready, []}],
        delete_effects: [{:ready, []}]
      }

      c2 = %CapabilityProfile{
        capability_id: "needs-ready",
        preconditions: [{:ready, []}],
        add_effects: [{:done, []}],
        delete_effects: []
      }

      assert CapabilityComposition.apply_effects([], c1) == []

      assert {:error, %{code: :composition_preconditions_unmet, detail: detail}} =
               CapabilityComposition.compose(c1, c2)

      assert detail.unmet == [{"ready", []}]
    end

    test "the default is the STRICT reading: an ambient prior state does not help unless supplied" do
      c1 = %CapabilityProfile{
        capability_id: "c1",
        add_effects: [{:a, []}],
        preconditions: [],
        delete_effects: []
      }

      c2 = %CapabilityProfile{
        capability_id: "c2",
        preconditions: [{:a, []}, {:b, []}],
        add_effects: [{:c, []}],
        delete_effects: []
      }

      # Strict: c1 alone does not establish `(b)`.
      assert {:error, %{code: :composition_preconditions_unmet, detail: detail}} =
               CapabilityComposition.compose(c1, c2)

      assert detail.unmet == [{"b", []}]

      # Frame-aware, explicitly requested at the call site:
      assert {:ok, composition} =
               CapabilityComposition.compose(c1, c2, initial_state: [{:b, []}])

      assert composition.resulting_state == [{"a", []}, {"b", []}, {"c", []}]
    end

    test "atom-shaped and string-shaped facts are the same fact" do
      dsl_side = %CapabilityProfile{
        capability_id: "dsl",
        preconditions: [],
        add_effects: [{:at, [:room_a]}],
        delete_effects: []
      }

      wire_side = %CapabilityProfile{
        capability_id: "wire",
        preconditions: [{"at", ["room_a"]}],
        add_effects: [{"arrived", []}],
        delete_effects: []
      }

      assert {:ok, composition} = CapabilityComposition.compose(dsl_side, wire_side)
      assert composition.resulting_state == [{"arrived", []}, {"at", ["room_a"]}]
    end

    test "entails?/2 and unmet/2 agree with each other" do
      state = [{:a, []}, {:b, [:x]}]

      assert CapabilityComposition.entails?(state, [{:a, []}])
      assert CapabilityComposition.entails?(state, [{"b", ["x"]}])
      refute CapabilityComposition.entails?(state, [{:c, []}])

      assert CapabilityComposition.unmet(state, [{:a, []}, {:c, []}]) == [{"c", []}]
      assert CapabilityComposition.unmet(state, [{:a, []}]) == []
    end

    test "self-composition is refused" do
      c = advance(:open, :close, id: "same")

      assert {:error, %{code: :composition_self_composition, detail: "same"}} =
               CapabilityComposition.compose(c, c)
    end
  end

  describe "S48 -- composing MUST NOT raise either participant's authority ceiling" do
    test "each participant's requirement is preserved verbatim, per participant" do
      low = advance(:open, :mid, id: "low", authority_requirement: %{mode: :none})

      high =
        advance(:mid, :close,
          id: "high",
          authority_requirement: %{mode: :required, scope: "admin", expires_in_s: 60}
        )

      assert {:ok, composition} = CapabilityComposition.compose(low, high)

      assert composition.authority_requirements == %{
               "low" => %{mode: :none},
               "high" => %{mode: :required, scope: "admin", expires_in_s: 60}
             }

      # The low-authority participant did NOT inherit the high one's ceiling.
      assert composition.authority_requirements["low"] == low.authority_requirement
      assert composition.authority_requirements["low"] != high.authority_requirement

      # And the high one was not lowered either -- independence cuts both ways.
      assert composition.authority_requirements["high"] == high.authority_requirement
    end

    test "raises_ceiling?/2 returns [] for a conforming composition" do
      c1 = advance(:open, :mid, id: "c1", authority_requirement: %{mode: :none})
      c2 = advance(:mid, :close, id: "c2", authority_requirement: %{mode: :required})

      {:ok, composition} = CapabilityComposition.compose(c1, c2)

      assert CapabilityComposition.raises_ceiling?(composition, [c1, c2]) == []
    end

    test "raises_ceiling?/2 names exactly the participant whose requirement was altered" do
      c1 = advance(:open, :mid, id: "c1", authority_requirement: %{mode: :none})
      c2 = advance(:mid, :close, id: "c2", authority_requirement: %{mode: :required})

      {:ok, composition} = CapabilityComposition.compose(c1, c2)

      # Simulate the forbidden rollup: c1 is silently granted c2's ceiling.
      escalated = %{
        composition
        | authority_requirements: %{
            "c1" => %{mode: :required},
            "c2" => %{mode: :required}
          }
      }

      assert CapabilityComposition.raises_ceiling?(escalated, [c1, c2]) == ["c1"]
    end

    test "the Composition struct has no aggregate authority field to roll up into" do
      c1 = advance(:open, :mid, id: "c1")
      c2 = advance(:mid, :close, id: "c2")
      {:ok, composition} = CapabilityComposition.compose(c1, c2)

      keys = composition |> Map.from_struct() |> Map.keys()

      refute :effective_authority in keys
      refute :authority_ceiling in keys
      refute :combined_authority in keys
      assert :authority_requirements in keys

      # The only `authority` field is the constant fence.
      assert composition.authority == :none
    end

    test "consequence classes stay per-participant and are not rolled up" do
      observe = advance(:open, :mid, id: "obs", consequence: :observe)
      external = advance(:mid, :close, id: "ext", consequence: :external_do)

      {:ok, composition} = CapabilityComposition.compose(observe, external)

      assert composition.consequence_classes == %{"obs" => :observe, "ext" => :external_do}
    end

    test "authority requirements survive a multi-hop chain unchanged" do
      a = advance(:open, :b, id: "a", authority_requirement: %{mode: :none})
      b = advance(:b, :c, id: "b", authority_requirement: %{mode: :required, scope: "x"})
      c = advance(:c, :close, id: "c", authority_requirement: %{mode: :denied})

      assert {:ok, {compositions, final_state}} = CapabilityComposition.chain([a, b, c])

      assert length(compositions) == 2
      assert final_state == [{"current-phase", ["close"]}]

      # `raises_ceiling?/2` is scoped to a single composition's own
      # participants: hop 0 is a->b, hop 1 is b->c. (Handing it a
      # non-participant correctly reports a discrepancy -- the composition
      # records `nil` for a capability it does not involve -- so each hop is
      # checked against exactly its own two profiles.)
      [ab, bc] = compositions
      assert CapabilityComposition.raises_ceiling?(ab, [a, b]) == []
      assert CapabilityComposition.raises_ceiling?(bc, [b, c]) == []

      # Every declared requirement is still exactly what its own capability
      # declared, nowhere raised by the chaining.
      all = compositions |> Enum.map(& &1.authority_requirements) |> Enum.reduce(&Map.merge/2)

      assert all == %{
               "a" => a.authority_requirement,
               "b" => b.authority_requirement,
               "c" => c.authority_requirement
             }

      # `b` participates in BOTH hops and its requirement is identical in
      # each -- being composed twice did not accumulate anything.
      assert ab.authority_requirements["b"] == bc.authority_requirements["b"]
      assert ab.authority_requirements["b"] == b.authority_requirement
    end
  end

  describe "chaining" do
    test "chain/2 threads real state forward without double-applying effects" do
      a = advance(:open, :mid, id: "a")
      b = advance(:mid, :close, id: "b")

      assert {:ok, {[one], final}} = CapabilityComposition.chain([a, b])

      assert one.resulting_state == [{"current-phase", ["close"]}]
      assert final == [{"current-phase", ["close"]}]
    end

    test "chain/2 reports the failing hop index" do
      a = advance(:open, :mid, id: "a")
      b = advance(:mid, :close, id: "b")
      broken = advance(:nowhere, :elsewhere, id: "broken")

      assert {:error, refusal} = CapabilityComposition.chain([a, b, broken])
      assert refusal.code == :composition_preconditions_unmet
      assert refusal.hop == 1
    end

    test "a single-profile chain yields no compositions and just its own effects" do
      a = advance(:open, :close, id: "a")

      assert {:ok, {[], final}} =
               CapabilityComposition.chain([a], initial_state: [{:"current-phase", [:open]}])

      assert final == [{"current-phase", ["close"]}]
    end
  end

  describe "from_hddl_operator/3 reuses the real compiled capability shape" do
    test "builds a profile from a real AshA2A.Skill and a real AshA2A.HddlOperator" do
      skill = %AshA2A.Skill{id: "meeting/advance", consequence: :change}

      operator = %AshA2A.HddlOperator{
        parameters: [:from, :to],
        preconditions: [{:"current-phase", [:from]}],
        add_effects: [{:"current-phase", [:to]}],
        delete_effects: [{:"current-phase", [:from]}]
      }

      profile =
        CapabilityComposition.from_hddl_operator(skill, operator,
          authority_requirement: %{mode: :required}
        )

      assert profile.capability_id == "meeting/advance"
      assert profile.consequence == :change
      # No fact-shape translation happened -- the tuples came through as-is.
      assert profile.preconditions == operator.preconditions
      assert profile.add_effects == operator.add_effects
      assert profile.delete_effects == operator.delete_effects
      assert profile.authority_requirement == %{mode: :required}
    end
  end
end

# --- SECTION 2: Original test/ash_a2a/semantic_compiler_bounds_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.CompilerBoundsTest do
  @moduledoc """
  SEC-09 court: `AshA2A.Semantic.Compiler` refuses oversized source text and
  oversized batches BEFORE any model invocation. The `:generate_object`
  seam is a real function that records each invocation in this test
  process's own mailbox; "the model was never called" is a real mailbox
  read, not an interaction mock.
  """
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{Compiler, Source}
  alias AshA2A.Test.Fixture.Echo

  defp counting_generate do
    test_pid = self()

    fn _model, _prompt, _schema, _opts ->
      send(test_pid, :model_called)
      {:error, :stop_after_count}
    end
  end

  test "text over the byte ceiling is refused and the model is never called" do
    text = String.duplicate("a", 65)

    assert {:error, %{code: :semantic_text_too_large, detail: %{bytes: 65, max_text_bytes: 64}}} =
             Compiler.compile(Echo, text,
               generate_object: counting_generate(),
               max_text_bytes: 64
             )

    refute_received :model_called
  end

  test "compile_source/3 enforces the same ceiling" do
    source = Source.new(String.duplicate("b", 100))

    assert {:error, %{code: :semantic_text_too_large}} =
             Compiler.compile_source(Echo, source,
               generate_object: counting_generate(),
               max_text_bytes: 99
             )

    refute_received :model_called
  end

  test "text at the ceiling reaches the model" do
    text = String.duplicate("c", 64)

    assert {:error, _} =
             Compiler.compile(Echo, text,
               generate_object: counting_generate(),
               max_text_bytes: 64
             )

    assert_received :model_called
  end

  test "the default ceiling is 16 KiB" do
    assert Compiler.max_text_bytes() == 16_384
  end

  test "an oversized batch is refused before any worker starts" do
    assert {:error, %{code: :semantic_batch_too_large, detail: %{count: 3, max_batch: 2}}} =
             Compiler.compile_many(Echo, ["x", "y", "z"],
               generate_object: counting_generate(),
               max_batch: 2
             )

    refute_received :model_called
  end

  test "a malformed bound (e.g. an unparsed env string) falls back to the default, not open" do
    assert Compiler.max_text_bytes(max_text_bytes: "999999999") == 16_384
    text = String.duplicate("d", 16_385)

    assert {:error, %{code: :semantic_text_too_large, detail: %{max_text_bytes: 16_384}}} =
             Compiler.compile(Echo, text,
               generate_object: counting_generate(),
               max_text_bytes: "999999999"
             )

    refute_received :model_called

    assert {:error, %{code: :semantic_batch_too_large, detail: %{max_batch: 100}}} =
             Compiler.compile_many(Echo, List.duplicate("x", 101),
               generate_object: counting_generate(),
               max_batch: :infinity
             )

    refute_received :model_called
  end

  test "refusal codes are S42-classified" do
    assert Compiler.__sa2a_refusal_codes__() == %{
             semantic_text_too_large: :refused_bounds,
             semantic_batch_too_large: :refused_bounds
           }
  end
end

# --- SECTION 3: Original test/ash_a2a/semantic_compiler_hddl_solver_verification_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.CompilerHddlSolverVerificationTest do
  @moduledoc """
  Closes the "HDDL/FOND text is never solver-verified" gap: proves that
  HDDL/FOND text reaching `AshA2A.Semantic.ExecutionPackage` through the real
  semantic compiler pipeline is genuinely solvable by the real, CI-built
  `native/hddl_cli` (ferroplan) binary -- not merely plausible-looking
  placeholder strings like `"(:task lead)"`.

  Uses the repo's existing known-solvable real fixture pair
  (`test/support/hddl/freedom_gym_meeting/{domain,problem}.hddl`), already
  proven solvable by `test/ash_a2a_freedom_gym_hddl_plan_test.exs`.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.Compiler
  alias AshA2A.Test.Fixture.Echo
  alias AshA2A.Test.Fixture.SemanticHddlVerification

  @hddl_dir Path.expand("../support/hddl/freedom_gym_meeting", __DIR__)
  @domain_path Path.join(@hddl_dir, "domain.hddl")
  @problem_path Path.join(@hddl_dir, "problem.hddl")

  test "the real fixture domain/problem pair is solved by the real hddl_cli binary" do
    assert {:ok, decoded} =
             SemanticHddlVerification.verify_solves!(@domain_path, @problem_path)

    assert decoded["solved"] == true
  end

  test "HDDL/FOND text produced by the real Compiler.compile/3 pipeline is genuinely solver-verifiable" do
    # This test proves an end-to-end property: whatever HDDL/FOND text ends
    # up inside package.plan_candidate.plan["synthesis"] after passing
    # through the real Compiler.compile/3 -> IR -> Ontology -> PlanningIR ->
    # SemanticSynthesis admission chain is real, solver-verifiable text --
    # not an arbitrary placeholder like "(:task lead)".
    #
    # domain.hddl and problem.hddl do not map 1:1 onto the "hddl" vs "fond"
    # field names that Compiler/SemanticSynthesis use (those names describe
    # a task-network candidate vs. a FOND policy candidate, not a
    # domain-file vs. problem-file split). Per the task's explicit guidance,
    # we therefore inject the real domain.hddl content as the "hddl" field
    # and the real problem.hddl content as the "fond" field -- both are
    # genuinely real, solver-verifiable HDDL/FOND source text pulled
    # verbatim from disk, and after extraction from the compiled package we
    # write them back out to temp files and re-verify each one is
    # independently solvable together as a pair. This proves the pipeline
    # carries real, non-fabricated planner text end-to-end, independent of
    # exactly which JSON key it landed under.
    real_domain_text = File.read!(@domain_path)
    real_problem_text = File.read!(@problem_path)

    extract = fn _, _, _, _ -> {:ok, extraction()} end

    plan = fn _, _, _, _ ->
      {:ok,
       %{
         "request_id" => "semantic-plan-hddl-solver-verification",
         "authority" => "none",
         "capability_ids" => ["AshA2A.Test.Fixture.Echo.read"],
         "hddl" => real_domain_text,
         "fond" => real_problem_text
       }}
    end

    assert {:ok, package} =
             Compiler.compile(Echo, "The meeting should advance through every phase to close.",
               generate_object: extract,
               plan_generate_object: plan
             )

    assert package.semantic_ir.standing == :admitted
    assert package.ontology.standing == :admitted
    assert package.planning_ir.standing == :admitted
    assert package.plan_candidate.formalism == :hddl_fond
    assert package.authority == :none

    synthesis = package.plan_candidate.plan["synthesis"]
    compiled_domain_text = synthesis["hddl"]
    compiled_problem_text = synthesis["fond"]

    assert compiled_domain_text == real_domain_text
    assert compiled_problem_text == real_problem_text

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "semantic_hddl_solver_verification_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    tmp_domain_path = Path.join(tmp_dir, "domain.hddl")
    tmp_problem_path = Path.join(tmp_dir, "problem.hddl")

    File.write!(tmp_domain_path, compiled_domain_text)
    File.write!(tmp_problem_path, compiled_problem_text)

    assert {:ok, decoded} =
             SemanticHddlVerification.verify_solves!(tmp_domain_path, tmp_problem_path)

    assert decoded["solved"] == true
  end

  defp extraction do
    AshA2A.Semantic.IR.fields()
    |> Map.new(&{Atom.to_string(&1), []})
    |> Map.put("authority", "none")
    |> Map.put("goals", [
      %{
        "id" => "advance-meeting",
        "kind" => "goal",
        "description" => "advance the meeting through every phase to close",
        "source_quote" => "The meeting should advance through every phase to close."
      }
    ])
  end
end

# --- SECTION 4: Original test/ash_a2a/semantic_compiler_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.CompilerTest do
  use ExUnit.Case, async: true

  alias AshA2A.{Identity, Receipt}
  alias AshA2A.Semantic.{Compiler, ExecutionPackage, Feedback, IR}
  alias AshA2A.Test.Fixture.Echo

  test "compiles text through ontology and HDDL/FOND candidate without DO" do
    extract = fn _, _, _, _ -> {:ok, extraction()} end

    plan = fn _, _, _, _ ->
      {:ok,
       %{
         "request_id" => "semantic-plan-1",
         "authority" => "none",
         "capability_ids" => ["AshA2A.Test.Fixture.Echo.read"],
         "hddl" => "(:task lead)",
         "fond" => "(:policy observe-or-replan)"
       }}
    end

    assert {:ok, package} =
             Compiler.compile(Echo, "The goal is to lead the people.",
               generate_object: extract,
               plan_generate_object: plan
             )

    assert package.semantic_ir.standing == :admitted
    assert package.ontology.standing == :admitted
    assert package.planning_ir.standing == :admitted
    assert package.plan_candidate.formalism == :hddl_fond
    assert package.authority == :none
  end

  defp default_plan do
    fn _, _, _, _ ->
      {:ok,
       %{
         "request_id" => "semantic-plan-1",
         "authority" => "none",
         "capability_ids" => ["AshA2A.Test.Fixture.Echo.read"],
         "hddl" => "(:task lead)",
         "fond" => "(:policy observe-or-replan)"
       }}
    end
  end

  test "compile_many/3 preserves ordering and isolates one admission failure" do
    text1 = "The goal is to lead the people."
    text2 = "The goal is to feed the people."
    text3 = "The goal is to read the people."

    extract = fn _, prompt, _, _ ->
      cond do
        String.contains?(prompt, text2) ->
          {:ok,
           extraction()
           |> put_in(["goals"], [
             %{
               "id" => "lead",
               "kind" => "goal",
               "description" => "lead the people",
               "source_quote" => "this quote is not in the source text at all"
             }
           ])}

        String.contains?(prompt, text1) ->
          {:ok, extraction()}

        true ->
          {:ok, extraction_for(text3)}
      end
    end

    results =
      Compiler.compile_many(Echo, [text1, text2, text3],
        generate_object: extract,
        plan_generate_object: default_plan()
      )

    assert [ok1, err2, ok3] = results
    assert {:ok, %ExecutionPackage{}} = ok1
    assert {:error, %{code: :ungrounded_assertion}} = err2
    assert {:ok, %ExecutionPackage{}} = ok3
  end

  test "compile_many/3 converts a raised exception into a worker-exit error at its slot" do
    text1 = "The goal is to lead the people."
    text2 = "The goal is to feed the people."
    text3 = "The goal is to read the people."

    extract = fn _, prompt, _, _ ->
      cond do
        String.contains?(prompt, text2) -> raise "boom"
        String.contains?(prompt, text1) -> {:ok, extraction()}
        true -> {:ok, extraction_for(text3)}
      end
    end

    results =
      Compiler.compile_many(Echo, [text1, text2, text3],
        generate_object: extract,
        plan_generate_object: default_plan()
      )

    assert [ok1, {:error, %{code: :semantic_worker_exit, detail: _}}, ok3] = results
    assert {:ok, %ExecutionPackage{}} = ok1
    assert {:ok, %ExecutionPackage{}} = ok3
  end

  test "replan/4 folds a real receipt into a new candidate as an observation" do
    extract = fn _, _, _, _ -> {:ok, extraction()} end

    assert {:ok, package} =
             Compiler.compile(Echo, "The goal is to lead the people.",
               generate_object: extract,
               plan_generate_object: default_plan()
             )

    receipt = %Receipt{
      receipt_id: Identity.runtime("receipt-1"),
      command_id: Identity.command("command-1"),
      execution_id: Identity.execution("execution-1"),
      agent_id: Identity.agent("agent-1"),
      principal_id: Identity.principal("principal-1"),
      capability_id: "AshA2A.Test.Fixture.Echo.read",
      fingerprint: "command-fingerprint",
      consequence: :read,
      status: :completed,
      standing: :observed,
      recorded_at: ~U[2026-09-13 20:00:00Z]
    }

    assert {:ok, %ExecutionPackage{parent_fingerprint: parent_fp, feedback: [_ | _]} = next,
            %Feedback{}} =
             Compiler.replan(Echo, package, receipt, plan_generate_object: default_plan())

    assert parent_fp == package.fingerprint
    assert next.fingerprint != package.fingerprint
  end

  test "replan/4 passes through an error unchanged (no with-else wrapping)" do
    extract = fn _, _, _, _ -> {:ok, extraction()} end

    assert {:ok, package} =
             Compiler.compile(Echo, "The goal is to lead the people.",
               generate_object: extract,
               plan_generate_object: default_plan()
             )

    receipt = %Receipt{
      receipt_id: Identity.runtime("receipt-2"),
      command_id: Identity.command("command-2"),
      execution_id: Identity.execution("execution-2"),
      agent_id: Identity.agent("agent-2"),
      principal_id: Identity.principal("principal-2"),
      capability_id: "AshA2A.Test.Fixture.Echo.read",
      fingerprint: "command-fingerprint-2",
      consequence: :read,
      status: :completed,
      standing: :observed,
      recorded_at: ~U[2026-09-13 20:00:00Z]
    }

    failing_plan = fn _, _, _, _ -> {:error, %{code: :boom_test}} end

    assert {:error, %{code: :boom_test}} =
             Compiler.replan(Echo, package, receipt, plan_generate_object: failing_plan)
  end

  test "compile_source/3 wraps a non-code-map error reason as semantic_compilation_failed" do
    failing_fn = fn _, _, _, _ -> {:error, "some raw string reason"} end

    assert {:error, %{code: :semantic_compilation_failed, detail: "some raw string reason"}} =
             Compiler.compile(Echo, "some text", generate_object: failing_fn)
  end

  defp extraction do
    IR.fields()
    |> Map.new(&{Atom.to_string(&1), []})
    |> Map.put("authority", "none")
    |> Map.put("goals", [
      %{
        "id" => "lead",
        "kind" => "goal",
        "description" => "lead the people",
        "source_quote" => "The goal is to lead the people."
      }
    ])
  end

  defp extraction_for(text) do
    IR.fields()
    |> Map.new(&{Atom.to_string(&1), []})
    |> Map.put("authority", "none")
    |> Map.put("goals", [
      %{
        "id" => "lead",
        "kind" => "goal",
        "description" => "goal grounded in source",
        "source_quote" => text
      }
    ])
  end
end

# --- SECTION 5: Original test/ash_a2a/semantic_conformance_dynamic_call_sites_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticConformanceDynamicCallSitesTest do
  @moduledoc """
  Regression cover for `check_no_llm_on_production_do_path/0` returning a
  vacuously-true `:met`.

  The defect: `collect_remote_modules/1` matched only
  `{:call, _, {:remote, _, {:atom, _, module}, _}, _}`, so a call whose
  module is a variable, or an `apply/3` whose module argument is computed,
  contributed no target at all. The check then concluded "none is an LLM
  module" from the targets it *could* see.

  A real scan of the real compiled DO-path beams found this is not
  hypothetical -- `AshA2A.CommandBus` carries variable-module call sites and
  `AshA2A.ReceiptOutbox` carries an `:erlang.apply/3` site -- and the check
  nonetheless returned:

      {:met, "scanned the real BEAM abstract code of 5 DO-path module(s)
       (...) covering 75 distinct remote-call target(s); none is an LLM
       module"}

  Everything below reads real abstract code out of real `.beam` files through
  the real `:beam_lib`, exactly as the production check does.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.Semantic.Conformance
  alias AshA2A.Test.{DynamicCallSiteFixture, StaticCallSiteFixture}

  describe "the blind spot is real and is now detected" do
    test "remote_call_targets/1 still sees only the literally named callee" do
      assert {:ok, targets} = Conformance.remote_call_targets(DynamicCallSiteFixture)

      # The literal call is visible ...
      assert AshA2A.Providers.NeverCalled in targets

      # ... and the three dynamic ones name nothing at all, which is the
      # blind spot. This assertion documents it rather than hiding it.
      assert {:ok, sites} = Conformance.dynamic_call_sites(DynamicCallSiteFixture)
      assert length(sites) >= 3
    end

    test "dynamic_call_sites/1 finds all three dynamic shapes" do
      assert {:ok, sites} = Conformance.dynamic_call_sites(DynamicCallSiteFixture)
      kinds = sites |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()

      assert :variable_module in kinds
      assert :dynamic_apply in kinds
      assert :dynamic_make_fun in kinds
    end

    test "it reports nothing for a module whose every callee is an atom literal" do
      assert {:ok, []} = Conformance.dynamic_call_sites(StaticCallSiteFixture)
    end

    test "every site carries a real source line" do
      assert {:ok, sites} = Conformance.dynamic_call_sites(DynamicCallSiteFixture)

      for {_kind, line} <- sites do
        assert is_integer(line) and line > 0
      end
    end

    test "unavailable abstract code is still an error, never a guess" do
      assert {:error, _} = Conformance.dynamic_call_sites(:erlang)
      assert {:error, _} = Conformance.remote_call_targets(NoSuchModuleAnywhere)
    end
  end

  describe "the production DO path really carries dynamic call sites" do
    test "CommandBus dispatches on a runtime module value" do
      assert {:ok, sites} = Conformance.dynamic_call_sites(AshA2A.CommandBus)
      assert sites != [], "expected the reproduced variable-module sites in CommandBus"
    end

    test "ReceiptOutbox carries an erlang:apply/3 site" do
      assert {:ok, sites} = Conformance.dynamic_call_sites(AshA2A.ReceiptOutbox)
      assert sites != []
    end
  end

  describe "the requirement is now :unverifiable, not a false :met" do
    test "check_no_llm_on_production_do_path/0 reports unverifiable and says why" do
      assert {:unverifiable, detail} = Conformance.check_no_llm_on_production_do_path()

      assert detail =~ "runtime value"
      assert detail =~ "AshA2A.CommandBus"
      assert detail =~ "not decidable by AST inspection"
    end

    test "it would still be :unmet, not :unverifiable, if a literal LLM target appeared" do
      # The dynamic-site branch must not swallow a real violation. The
      # fixture module carries a literal AshA2A.Providers.* call AND dynamic
      # sites; `llm_module?/1` classifies that literal target, and the
      # ordering in the check puts :unmet ahead of :unverifiable.
      assert {:ok, targets} = Conformance.remote_call_targets(DynamicCallSiteFixture)
      assert Enum.any?(targets, &Conformance.llm_module?/1)
    end
  end

  describe "the roll-up counts are corrected, and the earned level stays honest" do
    @tag timeout: 300_000
    test "the DO-path requirement is counted as unverifiable and earned_level stays :none" do
      results = Conformance.requirement_results()
      grouped = Enum.group_by(results, & &1.status)

      assert length(results) == 34

      # Before the fix: met 15, unmet 19, unverifiable 0. The DO-path
      # requirement moves out of :met and into :unverifiable.
      #
      # Since the feat/sa2a-root-manifest merge, `AshA2A.Semantic.RootManifest`
      # is a real loaded module, so `check_admitted_root_manifest/0` moves
      # from :unmet to :unverifiable by its own documented rule (a surface
      # exists; this check does not establish that it is admitted). Hence
      # unmet 18 and unverifiable 2, with :met unchanged.
      #
      # Absolute :met/:unmet counts are not pinned here: they move every time
      # a requirement's surface lands (met was 14, 20 at v26.11.13). The law
      # under test is the unverifiable set and the honest level, plus that
      # every requirement is counted exactly once.
      met = Map.get(grouped, :met, [])
      unmet = Map.get(grouped, :unmet, [])
      unverifiable = Map.get(grouped, :unverifiable, [])

      assert length(met) + length(unmet) + length(unverifiable) == 34
      assert length(unverifiable) == 2
      refute :no_llm_on_production_do_path in Enum.map(met, & &1.id)

      unverifiable = Map.get(grouped, :unverifiable, [])
      assert Enum.any?(unverifiable, &(&1.detail =~ "not decidable by AST inspection"))

      assert unverifiable |> Enum.map(& &1.id) |> Enum.sort() ==
               [:admitted_root_manifest, :no_llm_on_production_do_path]

      # An :unverifiable requirement blocks conformance exactly as hard as an
      # :unmet one, so nothing here buys a level.
      assert Conformance.earned_level(results) == :none
    end
  end
end

# --- SECTION 6: Original test/ash_a2a/semantic_construct_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.ConstructTest do
  @moduledoc """
  RFC-SA2A-001 S26: CONSTRUCT manufactures an artifact from admitted
  semantics (`A = mu(O*)`), must identify admitted inputs, manufacturer
  identity + version, target profile, produced artifact digest, and a
  construction receipt -- and implies no authority.

  The headline test manufactures with the **real** `hddl_cli` binary: a real
  `System.cmd/3` subprocess over the real
  `test/support/hddl/freedom_gym_meeting/` domain and problem, via the
  repo's existing real `AshA2A.Planning.HddlSolver.solve/3`. The artifact
  digest asserted below is a digest of a plan a real solver actually
  produced. Nothing about the manufacturer is stubbed.

  If `native/hddl_cli/target/release/hddl_cli` is not built, the real-solver
  test is a **named, visible skip** (never a silent substitution of a canned
  plan) -- the Chicago-style degradation rule. The rest of the S26 surface
  is exercised with real, simple, hand-written manufacturer functions, which
  are real implementations with real behavior, not interaction-verifying
  mocks.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Planning.HddlSolver
  alias AshA2A.Semantic.{CanonicalTermDigest, Construct, PlanPackage}
  alias AshA2A.SemanticSubject
  alias AshA2A.Test.SA2APlanFixture, as: Fixture

  @manufacturer_opts [
    manufacturer_identity: "AshA2A.Planning.HddlSolver",
    manufacturer_version: "hddl_cli@release"
  ]

  defp built? do
    File.exists?(HddlSolver.cli_path())
  end

  defp package_and_projection(overrides \\ []) do
    {projection, _ontology} = Fixture.projection()

    {:ok, pkg} =
      PlanPackage.from_projection(
        projection,
        "AshA2A.Planning.HddlSolver",
        Fixture.strict_opts(overrides)
      )

    {pkg, projection}
  end

  # A real 1-arity function that genuinely shells out to the real solver.
  # Not a stub point: this is the production manufacturer shape.
  defp real_hddl_manufacturer do
    domain = File.read!(Path.join(Fixture.hddl_fixture_dir(), "domain.hddl"))
    problem = File.read!(Path.join(Fixture.hddl_fixture_dir(), "problem.hddl"))

    fn %PlanPackage{} -> HddlSolver.solve(domain, problem) end
  end

  describe "S26 -- A = mu(O*) with the real hddl_cli solver" do
    @tag :hddl_cli
    test "constructs a real plan artifact and identifies everything S26 requires" do
      if built?() do
        {pkg, projection} = package_and_projection()

        assert {:ok, construction} =
                 Construct.construct(
                   pkg,
                   projection,
                   real_hddl_manufacturer(),
                   @manufacturer_opts
                 )

        # The artifact is a REAL solver result, not a fabricated map.
        assert construction.artifact["solved"] == true
        assert is_list(construction.artifact["policy"])
        assert construction.artifact["policy"] != []

        # It really planned the freedom-gym phase chain.
        actions = Enum.map(construction.artifact["policy"], & &1["action"])
        assert Enum.any?(actions, &String.contains?(&1, "advance(open,trust-god)"))
        assert Enum.any?(actions, &String.contains?(&1, "advance(fellowship,close)"))

        # produced artifact digest
        assert construction.artifact_digest =~ ~r/\Asha256:[0-9a-f]{64}\z/
        assert construction.artifact_digest == CanonicalTermDigest.digest(construction.artifact)

        # manufacturer identity + version
        assert construction.manufacturer_identity == "AshA2A.Planning.HddlSolver"
        assert construction.manufacturer_version == "hddl_cli@release"

        # target profile
        assert construction.target_profile == :strict

        # admitted inputs
        assert construction.admitted_input_digests == [
                 projection.source_graph_digest,
                 projection.projection_digest,
                 pkg.plan_digest
               ]

        # construction receipt
        receipt = construction.construction_receipt
        assert receipt.kind == :construction_receipt
        assert receipt.artifact_digest == construction.artifact_digest
        assert receipt.plan_digest == pkg.plan_digest
        assert receipt.source_graph_digest == projection.source_graph_digest
        assert receipt.standing == :candidate
        assert receipt.authority == :none
        assert receipt.receipt_digest =~ ~r/\Asha256:[0-9a-f]{64}\z/
      else
        IO.puts(
          "\n  SKIPPED (real hddl_cli not built at #{HddlSolver.cli_path()}): " <>
            "real-solver CONSTRUCT test. Build with: cd native/hddl_cli && cargo build --release"
        )
      end
    end

    @tag :hddl_cli
    test "manufacturing the same plan twice yields the identical artifact digest" do
      if built?() do
        {pkg, projection} = package_and_projection()
        manufacturer = real_hddl_manufacturer()

        {:ok, a} = Construct.construct(pkg, projection, manufacturer, @manufacturer_opts)
        {:ok, b} = Construct.construct(pkg, projection, manufacturer, @manufacturer_opts)

        assert a.artifact_digest == b.artifact_digest
        assert a.construction_receipt.receipt_digest == b.construction_receipt.receipt_digest
      else
        IO.puts("\n  SKIPPED (real hddl_cli not built): repeat-manufacture determinism test.")
      end
    end
  end

  describe "S26 -- identity reuses AshA2A.SemanticSubject, not a fourth digest triple" do
    test "the construction carries a real SemanticSubject built by its own constructor" do
      {pkg, projection} = package_and_projection()

      assert {:ok, construction} =
               Construct.construct(
                 pkg,
                 projection,
                 fn _pkg -> {:ok, %{plan: "p"}} end,
                 @manufacturer_opts
               )

      subject = construction.semantic_subject
      assert %SemanticSubject{} = subject

      # `Ontology.fingerprint` is bare hex; `SemanticSubject` requires the
      # "sha256:" prefix. `Construct.normalize_digest/1` adapts at the
      # boundary rather than either side being loosened -- the bare-hex
      # ontology fingerprint is still recoverable from the subject.
      assert subject.graph_digest == "sha256:" <> projection.source_graph_digest

      assert {:ok, subject.graph_digest} ==
               Construct.normalize_digest(projection.source_graph_digest)

      # `plan_digest` is already produced by CanonicalTermDigest in prefixed form,
      # so it passes through untouched.
      assert subject.projection_digest == pkg.plan_digest

      assert subject.manufacturer_digest ==
               Construct.manufacturer_digest(
                 "AshA2A.Planning.HddlSolver",
                 "hddl_cli@release",
                 :strict
               )

      # SemanticSubject's own real format gate accepted it, so a command can
      # carry it for replay scoping without reformatting.
      assert {:ok, ^subject} =
               SemanticSubject.new(
                 graph_digest: subject.graph_digest,
                 projection_digest: subject.projection_digest,
                 manufacturer_digest: subject.manufacturer_digest
               )
    end

    test "manufacturer_digest is stable across inputs and varies with version" do
      a = Construct.manufacturer_digest("m", "1.0.0", :strict)
      b = Construct.manufacturer_digest("m", "1.0.0", :strict)
      c = Construct.manufacturer_digest("m", "1.0.1", :strict)
      d = Construct.manufacturer_digest("m", "1.0.0", :permissive)

      assert a == b
      refute a == c
      refute a == d
    end

    test "two different artifacts from the same manufacturer share a manufacturer digest" do
      {pkg, projection} = package_and_projection()

      {:ok, one} =
        Construct.construct(pkg, projection, fn _pkg -> {:ok, %{n: 1}} end, @manufacturer_opts)

      {:ok, two} =
        Construct.construct(pkg, projection, fn _pkg -> {:ok, %{n: 2}} end, @manufacturer_opts)

      assert one.semantic_subject.manufacturer_digest ==
               two.semantic_subject.manufacturer_digest

      refute one.artifact_digest == two.artifact_digest
    end
  end

  describe "S26 -- CONSTRUCT implies no authority" do
    test "the construction and its receipt are candidate-standing and authority-free" do
      {pkg, projection} = package_and_projection()

      {:ok, construction} =
        Construct.construct(pkg, projection, fn _pkg -> {:ok, :artifact} end, @manufacturer_opts)

      assert construction.standing == :candidate
      assert construction.authority == :none
      assert construction.construction_receipt.authority == :none
    end

    test "the compiled module's real import table reaches no consequence boundary" do
      {:ok, path} = AshA2A.BeamFile.path(Construct)
      {:ok, {Construct, [imports: imports]}} = :beam_lib.chunks(path, [:imports])
      modules = imports |> Enum.map(fn {mod, _f, _a} -> mod end) |> Enum.uniq()

      assert AshA2A.SemanticSubject in modules

      forbidden = [
        AshA2A.CommandBus,
        AshA2A.ReceiptStore,
        AshA2A.ReceiptOutbox,
        AshA2A.Receipt,
        AshA2A.Authority,
        AshA2A.KillSwitch
      ]

      assert Enum.filter(forbidden, &(&1 in modules)) == []
    end

    test "a construction receipt is not an AshA2A.Receipt and cannot pass as one" do
      {pkg, projection} = package_and_projection()

      {:ok, construction} =
        Construct.construct(pkg, projection, fn _pkg -> {:ok, :artifact} end, @manufacturer_opts)

      receipt = construction.construction_receipt

      refute match?(%AshA2A.Receipt{}, receipt)
      refute Map.has_key?(receipt, :command_id)
      refute Map.has_key?(receipt, :principal_id)
      refute Map.has_key?(receipt, :execution_id)
      refute Map.has_key?(receipt, :consequence)
    end
  end

  describe "S26/S27 -- construction refuses unverifiable admitted inputs" do
    test "a hand-edited projection cannot manufacture a canonical artifact" do
      {pkg, projection} = package_and_projection()
      edited = %{projection | goals: ["a goal nobody admitted"]}

      assert {:error, %{code: :construct_projection_unverifiable, detail: detail}} =
               Construct.construct(
                 pkg,
                 edited,
                 fn _pkg -> {:ok, :artifact} end,
                 @manufacturer_opts
               )

      assert detail.code == :projection_manual_edit_not_canonical
    end

    test "a hand-edited package cannot manufacture" do
      {pkg, projection} = package_and_projection()

      assert {:error, %{code: :construct_package_unverifiable}} =
               Construct.construct(
                 %{pkg | max_depth: 999},
                 projection,
                 fn _pkg -> {:ok, :artifact} end,
                 @manufacturer_opts
               )
    end

    test "a package and a projection that do not belong together are refused" do
      {pkg, _projection} = package_and_projection()

      {_other_pkg, other_projection} =
        package_and_projection(planning_domain_identity: "unrelated-domain")

      # Same fixture, so build a genuinely different projection instead.
      {:ok, moved_ontology} = AshA2A.Semantic.Ontology.from_ir(Fixture.admitted_ir())

      moved_planning =
        AshA2A.Semantic.PlanningIR.with_observation(Fixture.planning_ir(), %{"k" => "v"})

      {:ok, moved_projection} =
        AshA2A.Semantic.PlanProjection.from_admitted(
          %{moved_planning | ontology_fingerprint: moved_ontology.fingerprint},
          moved_ontology
        )

      refute moved_projection.projection_digest == other_projection.projection_digest

      assert {:error, %{code: :construct_projection_package_mismatch, detail: detail}} =
               Construct.construct(
                 pkg,
                 moved_projection,
                 fn _pkg -> {:ok, :artifact} end,
                 @manufacturer_opts
               )

      assert detail.package_names == pkg.projection_digest
      assert detail.projection_is == moved_projection.projection_digest
    end

    test "a real manufacturer failure is surfaced verbatim, not swallowed" do
      {pkg, projection} = package_and_projection()

      assert {:error, %{code: :construct_manufacturer_failed, detail: detail}} =
               Construct.construct(
                 pkg,
                 projection,
                 fn _pkg -> {:error, %{code: :hddl_unsolved, solved: false}} end,
                 @manufacturer_opts
               )

      assert detail == %{code: :hddl_unsolved, solved: false}
    end

    test "a manufacturer returning a non-result shape is a typed refusal" do
      {pkg, projection} = package_and_projection()

      assert {:error, %{code: :construct_manufacturer_invalid_result, detail: :whatever}} =
               Construct.construct(pkg, projection, fn _pkg -> :whatever end, @manufacturer_opts)
    end

    @tag :hddl_cli
    test "a genuinely unsolvable real problem refuses instead of manufacturing" do
      if built?() do
        dir = Path.expand("../support/hddl/unsolvable_qualification", __DIR__)
        domain = File.read!(Path.join(dir, "domain.hddl"))
        problem = File.read!(Path.join(dir, "problem.hddl"))
        {pkg, projection} = package_and_projection()

        assert {:error, %{code: :construct_manufacturer_failed, detail: detail}} =
                 Construct.construct(
                   pkg,
                   projection,
                   fn _pkg -> HddlSolver.solve(domain, problem) end,
                   @manufacturer_opts
                 )

        # The real solver's own refusal, carried through untouched.
        assert detail[:code] in [:hddl_unsolved, :hddl_solve_error]
      else
        IO.puts("\n  SKIPPED (real hddl_cli not built): unsolvable-problem refusal test.")
      end
    end
  end
end

# --- SECTION 7: Original test/ash_a2a/semantic_envelope_doctest_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticEnvelopeDoctestTest do
  @moduledoc """
  Runs the `@doc` doctests on the RFC-SA2A-001 S6/S11/S41/S42 semantic
  boundary modules for real.

  A separate module from `AshA2A.DoctestTest` so this layer's doctests are
  wired without touching that file's existing `AshA2A.Info` /
  `AshA2A.CapabilityIndex` / `AshA2A.ContextResolver` list.
  """

  use ExUnit.Case, async: true

  doctest AshA2A.Semantic.Refusal
  doctest AshA2A.Semantic.Envelope
  doctest AshA2A.Semantic.Standing
end

# --- SECTION 8: Original test/ash_a2a/semantic_envelope_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticEnvelopeTest do
  @moduledoc """
  Chicago-school tests for `AshA2A.Semantic.Envelope` (RFC-SA2A-001 S11).

  Real structs, real `Jason` encode/decode, real `AshA2A.Semantic.Standing`
  transitions to raise standing when a raised-standing envelope is needed.
  No mocking: every collaborator here (Jason, Standing, Refusal, Vocabulary)
  is real and runnable in-process, so there is nothing a double would buy.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{Envelope, Refusal, Standing, Vocabulary}

  defp minimal(overrides) do
    Map.merge(%{envelope_id: "urn:uuid:test-1", kind: "sa2a:Request"}, overrides)
  end

  defp new!, do: new!(%{})

  defp new!(overrides) do
    {:ok, envelope} = Envelope.new(minimal(overrides))
    envelope
  end

  describe "S11 shape" do
    test "carries every RFC S11 field with the documented defaults" do
      envelope = new!()

      assert envelope.profile == Envelope.default_profile()
      assert envelope.kind == "sa2a:Request"
      assert envelope.envelope_id == "urn:uuid:test-1"
      assert envelope.subjects == []
      assert envelope.standing == :candidate
      assert envelope.semantic_basis == []
      assert envelope.graph == nil
      assert envelope.provenance == %{}
      assert envelope.consequence_class == "none"
      assert envelope.authority_requirement == "none"
      assert envelope.bounds == %{}
      assert envelope.receipts == []
      assert envelope.standing_history == []
    end

    test "consequenceClass and authorityRequirement default to \"none\"" do
      assert new!().consequence_class == "none"
      assert new!().authority_requirement == "none"
    end

    test "accepts a full graph triple of mediaType/digest/content" do
      graph = %{
        media_type: "text/turtle",
        digest: "blake3:9b8180962a93910d17c51d029626f393",
        content: "@prefix ex: <https://example.org/> . ex:a ex:b ex:c ."
      }

      envelope = new!(%{graph: graph})
      assert envelope.graph == graph
    end

    test "accepts camelCase string keys as well as atom keys" do
      {:ok, envelope} =
        Envelope.new(%{
          "envelopeId" => "urn:uuid:string-keys",
          "kind" => "sa2a:Response",
          "consequenceClass" => "observe",
          "authorityRequirement" => "delegated",
          "semanticBasis" => ["urn:sa2a:basis:1"],
          "graph" => %{"mediaType" => "text/turtle", "digest" => "d", "content" => "c"}
        })

      assert envelope.envelope_id == "urn:uuid:string-keys"
      assert envelope.consequence_class == "observe"
      assert envelope.authority_requirement == "delegated"
      assert envelope.semantic_basis == ["urn:sa2a:basis:1"]
      assert envelope.graph == %{media_type: "text/turtle", digest: "d", content: "c"}
    end
  end

  describe "candidate-only construction (the structural invariant)" do
    test "new/1 forces :candidate even when the caller passes standing: :candidate" do
      assert new!(%{standing: :candidate}).standing == :candidate
    end

    test "new/1 refuses a claimed standing above candidate" do
      assert {:error, %Refusal{} = refusal} = Envelope.new(minimal(%{standing: :admitted}))

      assert refusal.class == :refused_meta_rigor
      assert refusal.code == :standing_self_declared
      assert refusal.detail == :admitted
      assert refusal.lawful? == true
    end

    test "from_json/1 refuses every standing an inbound payload could claim" do
      for claimed <- Standing.states() ++ Standing.terminal_states(),
          claimed != :candidate do
        wire = Atom.to_string(claimed)

        json =
          Jason.encode!(%{
            "envelopeId" => "urn:uuid:claim",
            "kind" => "sa2a:Request",
            "standing" => wire
          })

        # The refused detail is the raw wire *string*, never an atomized
        # version of it -- wire input is never fed to String.to_atom/1.
        assert {:error, %Refusal{code: :standing_self_declared, detail: ^wire}} =
                 Envelope.from_json(json),
               "inbound payload claiming #{claimed} was not refused"
      end
    end

    test "from_json/1 refuses a fabricated standingHistory" do
      json =
        Jason.encode!(%{
          "envelopeId" => "urn:uuid:hist",
          "kind" => "sa2a:Request",
          "standingHistory" => [%{"from" => "candidate", "to" => "admitted"}]
        })

      assert {:error, %Refusal{} = refusal} = Envelope.from_json(json)
      assert refusal.class == :refused_meta_rigor
      assert refusal.code == :standing_history_declared
    end

    test "there is no exported constructor that yields a standing above :candidate" do
      # Every public 1-arity/2-arity constructor on the module, driven for
      # real with an admitted-claiming payload.
      claim = minimal(%{standing: :admitted})

      assert {:error, %Refusal{}} = Envelope.new(claim)
      assert {:error, %Refusal{}} = Envelope.from_map(%{claim | standing: :admitted})

      assert {:error, %Refusal{}} =
               Envelope.from_json(
                 Jason.encode!(%{
                   "envelopeId" => "urn:uuid:x",
                   "kind" => "sa2a:Request",
                   "standing" => "admitted"
                 })
               )

      # And the only lawful raise is a real evidenced transition.
      assert {:ok, raised} =
               Standing.transition(new!(), :received, %{
                 transport: "a2a/https",
                 received_at: "2026-09-16T00:00:00Z"
               })

      assert raised.standing == :received
    end
  end

  describe "to_json/1 <-> from_json/1 round trip" do
    test "a minimal candidate envelope round-trips byte-identically through JSON" do
      original = new!()

      assert {:ok, restored} = original |> Envelope.to_json() |> Envelope.from_json()
      assert restored == original
      assert Envelope.to_json(restored) == Envelope.to_json(original)
    end

    test "a fully-populated candidate envelope round-trips" do
      # String-keyed provenance/bounds because that is the real wire shape:
      # JSON has no atom keys, so an atom-keyed map would not survive any
      # honest round trip and the test would be lying about the wire.
      original =
        new!(%{
          profile: "urn:sa2a:profile:conformance:v26.9.16",
          kind: "sa2a:Task",
          subjects: ["urn:example:subject:1", "urn:example:subject:2"],
          semantic_basis: ["urn:sa2a:basis:shapes:v1"],
          graph: %{
            media_type: "text/turtle",
            digest: "blake3:610ccbcd4ed4b23cf4179fde360625da",
            content: "@prefix ex: <https://example.org/> .\nex:s ex:p ex:o ."
          },
          provenance: %{"agent" => "urn:example:agent:a", "wasDerivedFrom" => "urn:example:x"},
          consequence_class: "change",
          authority_requirement: "principal",
          bounds: %{"maxTriples" => 10_000},
          receipts: [%{"receiptId" => "urn:receipt:1"}]
        })

      json = Envelope.to_json(original)
      assert {:ok, restored} = Envelope.from_json(json)
      assert restored == original
    end

    test "to_map/1 emits exactly the RFC camelCase key set" do
      map = Envelope.to_map(new!())

      assert Enum.sort(Map.keys(map)) ==
               Enum.sort(~w(
                 profile kind envelopeId subjects standing semanticBasis graph
                 provenance consequenceClass authorityRequirement bounds
                 receipts standingHistory
               ))
    end

    test "a raised envelope serializes for audit but is NOT re-ingestible" do
      {:ok, received} =
        Standing.transition(new!(), :received, %{
          transport: "a2a/https",
          received_at: "2026-09-16T00:00:00Z"
        })

      json = Envelope.to_json(received)
      assert %{"standing" => "received"} = Jason.decode!(json)

      assert [%{"from" => "candidate", "to" => "received"}] =
               Jason.decode!(json)["standingHistory"]

      # Re-ingesting serialized standing would be exactly the
      # self-declaration S6 forbids. It is refused, not silently downgraded.
      assert {:error, %Refusal{code: :standing_self_declared}} = Envelope.from_json(json)
    end
  end

  describe "fail-closed validation (S43)" do
    test "a missing envelopeId is REFUSED_IDENTITY" do
      assert {:error, %Refusal{class: :refused_identity, code: :envelope_id_missing}} =
               Envelope.new(%{kind: "sa2a:Request"})

      assert {:error, %Refusal{code: :envelope_id_missing}} =
               Envelope.new(%{envelope_id: "", kind: "sa2a:Request"})
    end

    test "a missing kind is REFUSED_STRUCTURE" do
      assert {:error, %Refusal{class: :refused_structure, code: :kind_missing}} =
               Envelope.new(%{envelope_id: "urn:uuid:k"})
    end

    test "an unregistered kind prefix is REFUSED_NAMESPACE" do
      assert {:error, %Refusal{class: :refused_namespace, code: :kind_namespace_unregistered}} =
               Envelope.new(minimal(%{kind: "madeup:Request"}))

      assert {:error, %Refusal{code: :kind_namespace_unregistered}} =
               Envelope.new(minimal(%{kind: "NoPrefixAtAll"}))
    end

    test "every prefix the existing Vocabulary registry knows is admitted as a kind prefix" do
      for prefix <- Map.keys(Vocabulary.prefixes()) do
        assert {:ok, envelope} = Envelope.new(minimal(%{kind: "#{prefix}:Thing"}))
        assert envelope.kind == "#{prefix}:Thing"
      end
    end

    test "an unimplemented profile is UNSUPPORTED_PROFILE, not REFUSED_PROFILE" do
      assert {:error, %Refusal{} = refusal} =
               Envelope.new(minimal(%{profile: "urn:sa2a:profile:from-the-future:v99"}))

      assert refusal.class == :unsupported_profile
      assert refusal.code == :unknown_profile
      assert Refusal.terminal_standing(refusal) == :unsupported
    end

    test "a malformed profile is REFUSED_PROFILE" do
      assert {:error, %Refusal{class: :refused_profile, code: :profile_invalid}} =
               Envelope.new(minimal(%{profile: 42}))
    end

    test "a partial graph is REFUSED_STRUCTURE" do
      assert {:error, %Refusal{class: :refused_structure, code: :graph_shape_invalid}} =
               Envelope.new(minimal(%{graph: %{media_type: "text/turtle"}}))

      assert {:error, %Refusal{code: :graph_shape_invalid}} =
               Envelope.new(minimal(%{graph: %{"mediaType" => "text/turtle", "digest" => "d"}}))
    end

    test "an unknown consequenceClass is REFUSED_CONSEQUENCE" do
      assert {:error, %Refusal{class: :refused_consequence, code: :consequence_class_unknown}} =
               Envelope.new(minimal(%{consequence_class: "unknown"}))
    end

    test "every admissible consequenceClass is accepted" do
      for value <- Envelope.consequence_classes() do
        assert {:ok, envelope} = Envelope.new(minimal(%{consequence_class: value}))
        assert envelope.consequence_class == value
      end
    end

    test "an unknown authorityRequirement is REFUSED_AUTHORITY" do
      assert {:error, %Refusal{class: :refused_authority, code: :authority_requirement_unknown}} =
               Envelope.new(minimal(%{authority_requirement: "root"}))
    end

    test "non-list and non-map fields are REFUSED_STRUCTURE" do
      assert {:error, %Refusal{code: :envelope_field_invalid}} =
               Envelope.new(minimal(%{subjects: "not-a-list"}))

      assert {:error, %Refusal{code: :envelope_field_invalid}} =
               Envelope.new(minimal(%{provenance: "not-a-map"}))

      assert {:error, %Refusal{code: :envelope_field_invalid}} =
               Envelope.new(minimal(%{bounds: []}))
    end

    test "malformed JSON is REFUSED_STRUCTURE, never a raise" do
      assert {:error, %Refusal{class: :refused_structure, code: :envelope_json_invalid}} =
               Envelope.from_json("{not json")

      assert {:error, %Refusal{code: :envelope_json_invalid}} = Envelope.from_json("[1,2,3]")
    end

    test "a non-map payload is REFUSED_STRUCTURE" do
      assert {:error, %Refusal{code: :envelope_payload_invalid}} = Envelope.from_json(:nope)
      assert {:error, %Refusal{code: :envelope_payload_invalid}} = Envelope.new(:nope)
    end
  end

  describe "decode_standing/1" do
    test "decodes every real state without String.to_atom on wire input" do
      for state <- Standing.states() ++ Standing.terminal_states() do
        assert {:ok, ^state} = Envelope.decode_standing(Atom.to_string(state))
      end
    end

    test "an unrecognized standing string is refused, not coerced into a new atom" do
      assert {:error, %Refusal{class: :refused_structure, code: :standing_state_unknown}} =
               Envelope.decode_standing("sovereign")

      assert {:error, %Refusal{code: :standing_state_unknown}} = Envelope.decode_standing(:atom)
    end
  end

  describe "evidence_digest/1" do
    test "is order-independent over map keys" do
      assert Envelope.evidence_digest(%{a: 1, b: 2, c: 3}) ==
               Envelope.evidence_digest(%{c: 3, b: 2, a: 1})
    end

    test "changes when any value changes" do
      refute Envelope.evidence_digest(%{a: 1}) == Envelope.evidence_digest(%{a: 2})
      refute Envelope.evidence_digest(%{a: 1}) == Envelope.evidence_digest(%{b: 1})
    end

    test "is a real sha256 in the SemanticSubject digest format" do
      "sha256:" <> hex = Envelope.evidence_digest(%{a: 1})
      assert String.match?(hex, ~r/\A[0-9a-f]{64}\z/)
    end
  end

  describe "history_entry/3 and the ledger the real transition path writes" do
    test "an entry carries keys and a digest, never the raw evidence" do
      evidence = %{transport: "a2a/https", received_at: "2026-09-16T00:00:00Z", secret: "hunter2"}

      entry = Envelope.history_entry(:candidate, :received, evidence)

      assert entry.from == :candidate
      assert entry.to == :received
      assert entry.evidence_keys == ["received_at", "secret", "transport"]
      assert entry.evidence_digest == Envelope.evidence_digest(evidence)
      refute inspect(entry) =~ "hunter2"
    end

    test "history_entry/3 does not seal anything: only Standing.transition/3 mints a ledger" do
      # The entry constructor is pure -- it returns a map and never touches an
      # envelope, so it cannot be used to forge standing. Stapling a
      # hand-built entry onto an envelope produces an unsealed ledger, which
      # the real transition path refuses.
      forged = %{
        new!()
        | standing: :received,
          standing_history: [Envelope.history_entry(:candidate, :received, %{transport: "x"})]
      }

      assert forged.standing_seal == nil

      assert {:error, %Refusal{code: :standing_ledger_unsealed}} =
               Standing.transition(forged, :parsed, %{media_type: "text/turtle", triple_count: 1})
    end

    test "the real transition path appends an ordered, sealed, raw-evidence-free history" do
      {:ok, received} =
        Standing.transition(new!(), :received, %{
          transport: "a2a/https",
          received_at: "2026-09-16T00:00:00Z",
          secret: "hunter2"
        })

      {:ok, parsed} =
        Standing.transition(received, :parsed, %{media_type: "text/turtle", triple_count: 2})

      assert Enum.map(parsed.standing_history, & &1.to) == [:received, :parsed]
      assert Enum.map(parsed.standing_history, & &1.from) == [:candidate, :received]
      assert is_binary(parsed.standing_seal)

      # Raw evidence values never enter the envelope or its serialization.
      refute Envelope.to_json(parsed) =~ "hunter2"
    end

    test "the ledger seal is never serialized: standing stays audit evidence, not a credential" do
      {:ok, received} =
        Standing.transition(new!(), :received, %{transport: "a2a/https", received_at: "now"})

      map = Envelope.to_map(received)

      refute Map.has_key?(map, "standingSeal")
      refute Envelope.to_json(received) =~ received.standing_seal
    end
  end
end

# --- SECTION 9: Original test/ash_a2a/semantic_evidence_ref_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.EvidenceRefTest do
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.EvidenceRef

  defp ref(overrides \\ %{}) do
    Map.merge(
      %{
        "schema" => "sa2a.semantic-evidence-envelope.v1",
        "contractVersion" => "v26.9.29",
        "subject" => "urn:customer:42",
        "sourceDigest" => "sha256:" <> String.duplicate("a", 64),
        "graphDigest" => "sha256:" <> String.duplicate("b", 64),
        "replayIdentity" => "replay:customer:42",
        "envelopeDigest" => "sha256:" <> String.duplicate("c", 64),
        "authority" => "NONE",
        "consequence" => "EVIDENCE_ONLY"
      },
      overrides
    )
  end

  test "admits portable powerless evidence reference" do
    assert {:ok, admitted} = EvidenceRef.admit(ref())
    assert admitted["authority"] == "NONE"
    assert admitted["consequence"] == "EVIDENCE_ONLY"
    assert {:ok, "sha256:" <> digest} = EvidenceRef.digest(admitted)
    assert byte_size(digest) == 64
  end

  test "refuses authority smuggling" do
    assert {:error, %{code: :refused_semantic_evidence, subject: :authority}} =
             EvidenceRef.admit(ref(%{"authority" => "DO"}))
  end

  test "refuses missing replay identity" do
    assert {:error, %{subject: :replay_identity}} =
             EvidenceRef.admit(ref(%{"replayIdentity" => ""}))
  end
end

# --- SECTION 10: Original test/ash_a2a/semantic_execution_package_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.ExecutionPackageTest do
  use ExUnit.Case, async: true

  alias AshA2A.Planning.Candidate

  alias AshA2A.Semantic.{
    Admission,
    ExecutionPackage,
    IR,
    IrAdmissionSeal,
    Ontology,
    PlanningIR,
    Source
  }

  defp build_source(text \\ "The system shall greet the user.") do
    Source.new(text)
  end

  # Real admission, not a hand-set `standing: :admitted`: `IR.from_map/2`
  # builds a genuine `:candidate` IR and `Admission.admit/2` runs its full
  # provenance/grounding/goal check chain for real, so the returned IR
  # carries a real `AshA2A.Semantic.IrAdmissionSeal`-minted seal. See
  # "new/6 fence rejections" below for the hand-built, unsealed counterpart
  # this module's seal exists to refuse.
  defp build_admitted_ir(source) do
    payload = %{
      "authority" => "none",
      "goals" => [
        %{
          "id" => "goal-1",
          "kind" => "goal",
          "description" => "Greet the user",
          "source_quote" => source.text
        }
      ]
    }

    {:ok, candidate_ir} = IR.from_map(source.id, payload)
    {:ok, ir} = Admission.admit(source, candidate_ir)
    ir
  end

  defp build_ontology(ir) do
    {:ok, ontology} = Ontology.from_ir(ir)
    ontology
  end

  defp build_planning_ir(ir, ontology) do
    {:ok, planning_ir} = PlanningIR.from_ir(ir, ontology)
    planning_ir
  end

  defp build_candidate(plan \\ %{"authority" => "none"}) do
    Candidate.new(:test_planner, plan, [], formalism: :hddl_fond)
  end

  defp build_inputs do
    source = build_source()
    ir = build_admitted_ir(source)
    ontology = build_ontology(ir)
    planning_ir = build_planning_ir(ir, ontology)
    candidate = build_candidate()
    {source, ir, ontology, planning_ir, candidate}
  end

  describe "new/6 happy path" do
    test "returns an ok package with expected defaults" do
      {source, ir, ontology, planning_ir, candidate} = build_inputs()

      assert {:ok, package} = ExecutionPackage.new(source, ir, ontology, planning_ir, candidate)

      assert %ExecutionPackage{
               standing: :candidate,
               authority: :none,
               parent_fingerprint: nil,
               feedback: []
             } = package

      assert is_binary(package.fingerprint)
      assert String.length(package.fingerprint) == 64
      assert package.fingerprint == String.downcase(package.fingerprint)
      assert package.fingerprint =~ ~r/^[0-9a-f]{64}$/
    end
  end

  describe "new/6 fence rejections" do
    test "rejects ir with standing not :admitted" do
      {source, ir, ontology, planning_ir, candidate} = build_inputs()
      bad_ir = %{ir | standing: :candidate}

      assert ExecutionPackage.new(source, bad_ir, ontology, planning_ir, candidate) ==
               {:error, %{code: :semantic_package_authority_ceiling_violated}}
    end

    test "rejects ir with authority not :none" do
      {source, ir, ontology, planning_ir, candidate} = build_inputs()
      bad_ir = %{ir | authority: :invalid}

      assert ExecutionPackage.new(source, bad_ir, ontology, planning_ir, candidate) ==
               {:error, %{code: :semantic_package_authority_ceiling_violated}}
    end

    test "rejects ontology with authority not :none" do
      {source, ir, ontology, planning_ir, candidate} = build_inputs()
      bad_ontology = %{ontology | authority: :invalid}

      assert ExecutionPackage.new(source, ir, bad_ontology, planning_ir, candidate) ==
               {:error, %{code: :semantic_package_authority_ceiling_violated}}
    end

    test "rejects planning_ir with authority not :none" do
      {source, ir, ontology, planning_ir, candidate} = build_inputs()
      bad_planning_ir = %{planning_ir | authority: :invalid}

      assert ExecutionPackage.new(source, ir, ontology, bad_planning_ir, candidate) ==
               {:error, %{code: :semantic_package_authority_ceiling_violated}}
    end

    test "rejects candidate with standing not :candidate" do
      {source, ir, ontology, planning_ir, candidate} = build_inputs()
      bad_candidate = %{candidate | standing: :admitted}

      assert ExecutionPackage.new(source, ir, ontology, planning_ir, bad_candidate) ==
               {:error, %{code: :semantic_package_authority_ceiling_violated}}
    end

    test "rejects candidate with authority not :none" do
      {source, ir, ontology, planning_ir, candidate} = build_inputs()
      bad_candidate = %{candidate | authority: :invalid}

      assert ExecutionPackage.new(source, ir, ontology, planning_ir, bad_candidate) ==
               {:error, %{code: :semantic_package_authority_ceiling_violated}}
    end

    test "rejects a hand-built admitted ir carrying no admission seal" do
      # This is the exact gap `AshA2A.Semantic.IrAdmissionSeal` closes: a
      # struct literal claiming `standing: :admitted, authority: :none`
      # without ever having run `AshA2A.Semantic.Admission.admit/2`. Before
      # the seal existed, this was accepted by `ExecutionPackage.new/6`
      # identically to a real admission.
      {source, ir, ontology, planning_ir, candidate} = build_inputs()

      forged_ir = %IR{
        source_id: source.id,
        standing: :admitted,
        authority: :none,
        goals: ir.goals
      }

      refute forged_ir.admission_seal
      refute forged_ir.admission_receipt_id

      assert ExecutionPackage.new(source, forged_ir, ontology, planning_ir, candidate) ==
               {:error, %{code: :semantic_ir_unsealed, detail: %{source_id: source.id}}}
    end

    test "rejects a real admitted ir whose admission_seal has been tampered with" do
      {source, ir, ontology, planning_ir, candidate} = build_inputs()
      assert is_binary(ir.admission_seal)

      tampered_ir = %{ir | admission_seal: "hmac-sha256:" <> String.duplicate("0", 64)}

      assert ExecutionPackage.new(source, tampered_ir, ontology, planning_ir, candidate) ==
               {:error, %{code: :semantic_ir_seal_invalid, detail: %{source_id: source.id}}}
    end

    test "rejects a real admitted ir whose content changed after sealing" do
      {source, ir, ontology, planning_ir, candidate} = build_inputs()

      [goal] = ir.goals
      retitled_goal = %{goal | "description" => "Greet the user warmly"}
      mutated_ir = %{ir | goals: [retitled_goal]}

      assert ExecutionPackage.new(source, mutated_ir, ontology, planning_ir, candidate) ==
               {:error, %{code: :semantic_ir_seal_invalid, detail: %{source_id: source.id}}}
    end

    test "IrAdmissionSeal.verify/1 accepts a real admitted ir directly" do
      {_source, ir, _ontology, _planning_ir, _candidate} = build_inputs()
      assert IrAdmissionSeal.verify(ir) == :ok
    end
  end

  describe "new/6 opts threading" do
    test "threads parent_fingerprint and feedback when provided" do
      {source, ir, ontology, planning_ir, candidate} = build_inputs()

      assert {:ok, package} =
               ExecutionPackage.new(source, ir, ontology, planning_ir, candidate,
                 parent_fingerprint: "parent-1",
                 feedback: [%{"k" => "v"}]
               )

      assert package.parent_fingerprint == "parent-1"
      assert package.feedback == [%{"k" => "v"}]
    end

    test "defaults parent_fingerprint to nil and feedback to [] without opts" do
      {source, ir, ontology, planning_ir, candidate} = build_inputs()

      assert {:ok, package} = ExecutionPackage.new(source, ir, ontology, planning_ir, candidate)

      assert package.parent_fingerprint == nil
      assert package.feedback == []
    end
  end

  describe "fingerprint determinism/sensitivity" do
    test "identical inputs produce identical fingerprints" do
      {source, ir, ontology, planning_ir, candidate} = build_inputs()

      assert {:ok, package_a} = ExecutionPackage.new(source, ir, ontology, planning_ir, candidate)
      assert {:ok, package_b} = ExecutionPackage.new(source, ir, ontology, planning_ir, candidate)

      assert package_a.fingerprint == package_b.fingerprint
    end

    test "changing the source changes the fingerprint" do
      {source, ir, ontology, planning_ir, candidate} = build_inputs()
      assert {:ok, package_a} = ExecutionPackage.new(source, ir, ontology, planning_ir, candidate)

      other_source = build_source("A completely different source statement.")
      other_ir = build_admitted_ir(other_source)
      other_ontology = build_ontology(other_ir)
      other_planning_ir = build_planning_ir(other_ir, other_ontology)

      assert {:ok, package_b} =
               ExecutionPackage.new(
                 other_source,
                 other_ir,
                 other_ontology,
                 other_planning_ir,
                 candidate
               )

      refute package_a.fingerprint == package_b.fingerprint
    end

    test "changing the candidate's plan content changes the fingerprint" do
      {source, ir, ontology, planning_ir, candidate} = build_inputs()
      assert {:ok, package_a} = ExecutionPackage.new(source, ir, ontology, planning_ir, candidate)

      other_candidate = build_candidate(%{"authority" => "none", "extra" => "different-plan"})
      refute other_candidate.fingerprint == candidate.fingerprint

      assert {:ok, package_b} =
               ExecutionPackage.new(source, ir, ontology, planning_ir, other_candidate)

      refute package_a.fingerprint == package_b.fingerprint
    end
  end
end

# --- SECTION 11: Original test/ash_a2a/semantic_falsifier_s18_4_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticFalsifierS184Test do
  @moduledoc """
  Regression cover for the RFC S18.4 false negatives in
  `AshA2A.Semantic.FalsifierSuite.check_update/2`.

  Three real mutations of canonical state were admitted before the fix. Each
  appears below verbatim as the verifier reported it, with the reason the old
  target-scan missed it. The suite also pins the two controls the fix must
  not break -- a legitimate staging update stays permitted, an explicit
  canonical target stays refused -- and re-runs the fourteen S61 falsifiers to
  show none of them regressed.

  Every collaborator is real: the real `FalsifierSuite`, the real
  `FalsifierFixtures` graphs, and real SPARQL Update text.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{Falsifier, FalsifierFixtures, FalsifierSuite}

  @canonical "http://example.org/canonical"
  @staging "http://example.org/staging"
  @rdf_type "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"

  # A real classification graph: one canonical graph, one staging graph.
  defp graph do
    [
      {@canonical, @rdf_type, FalsifierSuite.sa("CanonicalGraph")},
      {@staging, @rdf_type, FalsifierSuite.sa("StagingGraph")}
    ]
  end

  defp check(update), do: FalsifierSuite.check_update(graph(), update)

  defp refused_because(update) do
    assert {:error, %{code: :refused_sparql_update_on_canonical, detail: detail}} = check(update)
    detail
  end

  describe "the three mutations the verifier found admitted" do
    test "1. canonical write target written as a prefixed name, masked by a staging IRI in WHERE" do
      # The old regex matched only `<...>`, so `GRAPH c:canonical` named no
      # target; the only target it found was the staging IRI in the read
      # clause, and it admitted.
      update = """
      PREFIX c: <http://example.org/>
      INSERT { GRAPH c:canonical { ?s ?p ?o } }
      WHERE  { GRAPH <#{@staging}> { ?s ?p ?o } }
      """

      detail = refused_because(update)

      assert detail.target_kind == :unresolvable_graph_operand
      assert detail.reason =~ "rather than an <IRIREF>"
    end

    test "2. unqualified INSERT template writing the default graph, masked by staging in WHERE" do
      # An INSERT template not opened by GRAPH writes the DEFAULT graph,
      # which in Strict is canonical consequential state.
      update = "INSERT { ?s ?p ?o } WHERE { GRAPH <#{@staging}> { ?s ?p ?o } }"

      detail = refused_because(update)

      assert detail.target == :default_graph
      assert detail.reason =~ "writes the default graph"
    end

    test "3. MOVE DEFAULT TO <staging>, which destroys the default graph" do
      # MOVE removes its source. `DEFAULT` is a keyword operand, not an
      # IRIREF, so the old scan saw only the staging IRI and admitted.
      detail = refused_because("MOVE DEFAULT TO <#{@staging}>")

      assert detail.target_kind == :keyword_graph_operand
      assert detail.reason =~ "DEFAULT/ALL/NAMED"
    end
  end

  describe "the controls the fix must not break" do
    test "a legitimate staging-graph update is still permitted" do
      assert :ok =
               check(
                 "INSERT DATA { GRAPH <#{@staging}> { <http://e/a> <http://e/p> <http://e/b> } }"
               )
    end

    test "every staging-scoped operation form stays permitted" do
      permitted = [
        "INSERT DATA { GRAPH <#{@staging}> { <http://e/a> <http://e/p> <http://e/b> } }",
        "DELETE DATA { GRAPH <#{@staging}> { <http://e/a> <http://e/p> <http://e/b> } }",
        "DELETE WHERE { GRAPH <#{@staging}> { ?s ?p ?o } }",
        "WITH <#{@staging}> DELETE { ?s ?p ?o } INSERT { ?s ?p <http://e/b> } WHERE { ?s ?p ?o }",
        "INSERT { GRAPH <#{@staging}> { ?s ?p ?o } } WHERE { ?s ?p ?o }",
        "CLEAR GRAPH <#{@staging}>",
        "DROP SILENT GRAPH <#{@staging}>",
        "CREATE GRAPH <#{@staging}>",
        "ADD GRAPH <#{@staging}> TO GRAPH <#{@staging}>"
      ]

      for update <- permitted do
        assert :ok = check(update), "wrongly refused a staging-only update: #{inspect(update)}"
      end
    end

    test "an explicit canonical target is still refused" do
      detail =
        refused_because(
          "INSERT DATA { GRAPH <#{@canonical}> { <http://e/a> <http://e/p> <http://e/b> } }"
        )

      assert detail.target == @canonical
      assert detail.target_kind == :graph_iri
    end

    test "a mutating update naming no graph at all is still refused" do
      assert %{target: :default_graph} =
               refused_because("INSERT DATA { <http://e/a> <http://e/p> <http://e/b> }")
    end

    test "an unclassified graph is not staging" do
      detail =
        refused_because(
          "INSERT DATA { GRAPH <http://example.org/nowhere> { <a:b> <a:c> <a:d> } }"
        )

      assert detail.target == "http://example.org/nowhere"
    end

    test "a non-mutating query is not an update" do
      assert :ok = check("SELECT ?s WHERE { GRAPH <#{@canonical}> { ?s ?p ?o } }")
      assert :ok = check("ASK { ?s ?p ?o }")
    end
  end

  describe "the other keyword-operand mutations of canonical state" do
    for update <- [
          "COPY <http://example.org/staging> TO DEFAULT",
          "MOVE <http://example.org/staging> TO DEFAULT",
          "ADD <http://example.org/staging> TO DEFAULT",
          "CLEAR DEFAULT",
          "CLEAR ALL",
          "DROP ALL",
          "DROP NAMED"
        ] do
      test "#{update} is refused" do
        assert {:error, %{code: :refused_sparql_update_on_canonical}} = check(unquote(update))
      end
    end
  end

  describe "comments and string literals can neither create nor mask evidence" do
    test "a staging IRI inside a comment does not authorise a default-graph write" do
      update = """
      # GRAPH <#{@staging}>
      INSERT DATA { <http://e/a> <http://e/p> <http://e/b> }
      """

      assert {:error, %{code: :refused_sparql_update_on_canonical}} = check(update)
    end

    test "a staging IRI inside a string literal does not authorise it either" do
      update = ~s|INSERT DATA { <http://e/a> <http://e/p> "GRAPH <#{@staging}>" }|

      assert {:error, %{code: :refused_sparql_update_on_canonical}} = check(update)
    end

    test "a mutating keyword hidden inside a literal is still treated as mutating" do
      # `mutating_form/1` runs over the raw text too, so scrubbing can only
      # ever add a refusal, never remove one.
      assert {:error, %{code: :refused_sparql_update_on_canonical}} =
               check(~s|SELECT ?s WHERE { ?s ?p "INSERT DATA" }|)
    end
  end

  describe "the fourteen S61 falsifiers still have teeth" do
    defp trips?(graph, id) do
      assert {:ok, tripped} = FalsifierSuite.evaluate(graph, id)
      tripped
    end

    test "none fires on the empty graph" do
      for %Falsifier{id: id} <- FalsifierSuite.falsifiers() do
        refute trips?([], id), "#{id} fired on the empty graph"
      end
    end

    test "each fires on its own positive fixture and not on its negative one" do
      for %Falsifier{id: id} <- FalsifierSuite.falsifiers() do
        assert {:ok, positive} = FalsifierFixtures.positive(id)
        assert {:ok, negative} = FalsifierFixtures.negative(id)

        assert trips?(positive, id), "#{id} did not fire on its own positive fixture"
        refute trips?(negative, id), "#{id} fired on its own negative fixture"
      end
    end

    test "each fires on exactly one of the fourteen independent positive fixtures" do
      # The discrimination claim: a falsifier that fired on several fixtures
      # would be detecting something more general than its own condition.
      for %Falsifier{id: id} <- FalsifierSuite.falsifiers() do
        fired_on =
          for {other, positive, _negative} <- FalsifierFixtures.all(),
              trips?(positive, id),
              do: other

        assert fired_on == [id], "#{id} fired on #{inspect(fired_on)}"
      end
    end

    test "all fourteen are present" do
      assert length(FalsifierSuite.falsifiers()) == 14
    end
  end
end

# --- SECTION 12: Original test/ash_a2a/semantic_feedback_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.FeedbackTest do
  use ExUnit.Case, async: true

  alias AshA2A.{Identity, Receipt}
  alias AshA2A.Planning.Candidate
  alias AshA2A.Semantic.{Admission, ExecutionPackage, Feedback, IR, Ontology, PlanningIR, Source}

  test "projects runtime receipt evidence back into the loop without authority" do
    source = Source.new("Echo capability should read a record.")

    # Real admission, not a hand-set `standing: :admitted`: IR.from_map/2
    # builds a genuine :candidate IR and Admission.admit/2 runs its full
    # check chain for real, so the returned IR carries a real
    # AshA2A.Semantic.IrAdmissionSeal-minted seal (see that module's docs).
    payload = %{
      "authority" => "none",
      "goals" => [
        %{
          "id" => "goal-1",
          "kind" => "goal",
          "description" => "Read the Echo record.",
          "source_quote" => "Echo capability should read a record."
        }
      ]
    }

    {:ok, candidate_ir} = IR.from_map(source.id, payload)
    {:ok, ir} = Admission.admit(source, candidate_ir)

    assert {:ok, ontology} = Ontology.from_ir(ir)
    assert {:ok, planning_ir} = PlanningIR.from_ir(ir, ontology)

    plan_candidate =
      Candidate.new(:semantic_synthesis, %{"hddl" => "", "fond" => ""}, ["Echo.read"],
        formalism: :hddl_fond
      )

    assert {:ok, package} =
             ExecutionPackage.new(source, ir, ontology, planning_ir, plan_candidate)

    receipt = %Receipt{
      receipt_id: Identity.runtime("receipt-1"),
      command_id: Identity.command("command-1"),
      execution_id: Identity.execution("execution-1"),
      agent_id: Identity.agent("agent-1"),
      principal_id: Identity.principal("principal-1"),
      capability_id: "Echo.read",
      fingerprint: "command-fingerprint",
      consequence: :read,
      status: :completed,
      standing: :observed,
      recorded_at: ~U[2026-09-13 20:00:00Z]
    }

    assert {:ok, feedback} = Feedback.from_receipt(package, receipt)
    assert feedback.standing == :observed
    assert feedback.authority == :none
    assert feedback.observation["status"] == "completed"
  end
end

# --- SECTION 13: Original test/ash_a2a/semantic_graph_law_replay_token_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticGraphLawReplayTokenTest do
  @moduledoc """
  Regression cover for the unreachable replay-divergence branch in
  `AshA2A.Semantic.GraphLaw.verdict/1`.

  The defect, as reproduced before the fix: the branch tested
  `replay_status == "REFUSED"`, a token the engine never emits for replay,
  so a real divergence was admitted.

      verdict(%{"replay" => %{"status" => "REPLAY_MISMATCH"}, ...})
        -> {:admitted, "deadbeef"}
      verdict(%{"replay" => %{"status" => "HASH_MISMATCH"}, ...})
        -> {:admitted, "deadbeef"}

  The engine's real vocabulary is read out of the real vendored wasm
  artifact, not out of documentation -- see
  `reads the status vocabulary out of the real vendored wasm` below.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.GraphLaw

  defp report(replay_status) do
    %{
      "graph_hash" => "deadbeef",
      "dialects" => [],
      "replay" => %{
        "status" => replay_status,
        "first_hash" => "aa",
        "second_hash" => "bb"
      }
    }
  end

  describe "the verifier's minimal reproducing input" do
    test "REPLAY_MISMATCH is refused, not admitted" do
      assert {:refused, :semantic_replay_divergence, detail} =
               GraphLaw.verdict(report("REPLAY_MISMATCH"))

      assert detail =~ "REPLAY_MISMATCH"
    end

    test "HASH_MISMATCH is refused, not admitted" do
      assert {:refused, :semantic_replay_divergence, _detail} =
               GraphLaw.verdict(report("HASH_MISMATCH"))
    end
  end

  describe "fail-closed over the whole token space" do
    test "an agreement token still admits" do
      assert {:admitted, "deadbeef"} = GraphLaw.verdict(report("ADMITTED"))
    end

    test "a not-exercised replay slot still admits" do
      assert {:admitted, "deadbeef"} = GraphLaw.verdict(report("UNSUPPORTED"))
      assert {:admitted, "deadbeef"} = GraphLaw.verdict(report("PROFILE_NOT_ADMITTED"))
    end

    test "an absent replay section is not a divergence" do
      assert {:admitted, "deadbeef"} =
               GraphLaw.verdict(%{"graph_hash" => "deadbeef", "dialects" => []})
    end

    test "REFUSED still refuses, so nothing the old branch caught is lost" do
      assert {:refused, :semantic_replay_divergence, _} = GraphLaw.verdict(report("REFUSED"))
    end

    test "a token this module has never seen refuses rather than admits" do
      assert {:refused, :semantic_replay_divergence, _} =
               GraphLaw.verdict(report("SOME_FUTURE_ENGINE_TOKEN"))

      assert {:refused, :semantic_replay_divergence, _} = GraphLaw.verdict(report(42))
    end
  end

  describe "the accepted token set matches the real engine artifact" do
    @wasm_candidates [
      "priv/graphlaw/praxis_graphlaw.wasm",
      "priv/graphlaw/praxis_graphlaw_wasm_bg.wasm"
    ]

    test "reads the status vocabulary out of the real vendored wasm" do
      case Enum.find(@wasm_candidates, &File.exists?(Path.join(File.cwd!(), &1))) do
        nil ->
          # The artifact is not vendored into this working tree. Report that
          # rather than silently passing on a substitute: there is no mock
          # engine standing in for it.
          IO.puts(
            "\n  [skipped] no vendored praxis_graphlaw wasm in this tree; " <>
              "the engine-vocabulary assertion needs the real artifact"
          )

        relative ->
          bytes = File.read!(Path.join(File.cwd!(), relative))

          # The engine's status enum is one contiguous run in the wasm data
          # segment, in declaration order.
          assert bytes =~
                   "ADMITTEDREFUSEDUNSUPPORTEDREPLAY_MISMATCHHASH_MISMATCHPROFILE_NOT_ADMITTED"

          # Every token this module treats as agreement is really a token the
          # engine can emit ...
          for token <- GraphLaw.replay_agreement_tokens() do
            assert bytes =~ token
          end

          # ... and the divergence tokens the engine really emits are NOT in
          # the agreement set. This is the assertion that would have failed
          # before the fix, when "REFUSED" was the only token checked.
          for token <- ["REPLAY_MISMATCH", "HASH_MISMATCH", "REFUSED"] do
            refute token in GraphLaw.replay_agreement_tokens()
          end
      end
    end
  end

  describe "S51: received is not admitted -- preserved" do
    test "a dialect the engine refused still refuses regardless of replay" do
      report = %{
        "graph_hash" => "deadbeef",
        "dialects" => [%{"dialect" => "SHACL", "status" => "REFUSED", "detail" => "minCount"}],
        "replay" => %{"status" => "ADMITTED"}
      }

      assert {:refused, :semantic_shape_violation, detail} = GraphLaw.verdict(report)
      assert detail =~ "SHACL"
    end

    test "an unhashable graph is refused, never admitted on a sender's word" do
      assert {:refused, :semantic_graph_unhashable, _} =
               GraphLaw.verdict(%{"dialects" => [], "replay" => %{"status" => "ADMITTED"}})
    end
  end
end

# --- SECTION 14: Original test/ash_a2a/semantic_ir_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.IRTest do
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.IR

  @all_fields ~w(entities relations events goals constraints capabilities authorities observations uncertainties exclusions temporal_relations causal_hypotheses unresolved)a

  describe "from_map/2" do
    test "happy path admits authority none and populated fields, defaulting the rest to []" do
      goal = %{"id" => "g1", "kind" => "goal", "source_quote" => "do the thing"}

      assert {:ok, %IR{} = ir} =
               IR.from_map("src-1", %{"goals" => [goal], "authority" => "none"})

      assert ir.source_id == "src-1"
      assert ir.standing == :candidate
      assert ir.authority == :none
      assert ir.goals == [goal]

      for field <- @all_fields, field != :goals do
        assert Map.fetch!(ir, field) == []
      end
    end

    test "authority other than the literal string \"none\" marks the struct :invalid" do
      assert {:ok, %IR{authority: :invalid}} =
               IR.from_map("src-2", %{"authority" => "granted"})
    end

    test "authority key entirely absent marks the struct :invalid" do
      assert {:ok, %IR{authority: :invalid}} = IR.from_map("src-3", %{})
    end

    test "a non-list field value is coerced to []" do
      assert {:ok, %IR{goals: []}} =
               IR.from_map("src-4", %{"goals" => "oops", "authority" => "none"})
    end

    test "returns an error tuple when given a non-map" do
      assert {:error, %{code: :invalid_semantic_ir, detail: "not a map"}} =
               IR.from_map("src-5", "not a map")
    end
  end

  describe "items/1" do
    test "returns [] for an empty IR" do
      {:ok, ir} = IR.from_map("src-6", %{})
      assert IR.items(ir) == []
    end

    test "flattens every populated field into {field, item} tuples in declared order" do
      entity = %{"id" => "e1", "kind" => "entity", "source_quote" => "an entity"}
      relation = %{"subject" => "e1", "predicate" => "rel", "object" => "e2"}
      goal = %{"id" => "g1", "kind" => "goal", "source_quote" => "goal quote"}
      unresolved = %{"id" => "u1", "kind" => "unresolved", "source_quote" => "?"}

      {:ok, ir} =
        IR.from_map("src-7", %{
          "entities" => [entity],
          "relations" => [relation],
          "goals" => [goal],
          "unresolved" => [unresolved],
          "authority" => "none"
        })

      assert IR.items(ir) == [
               {:entities, entity},
               {:relations, relation},
               {:goals, goal},
               {:unresolved, unresolved}
             ]
    end
  end

  describe "fields/0" do
    test "returns exactly the 13-atom declared field list, pinned against drift" do
      assert IR.fields() == [
               :entities,
               :relations,
               :events,
               :goals,
               :constraints,
               :capabilities,
               :authorities,
               :observations,
               :uncertainties,
               :exclusions,
               :temporal_relations,
               :causal_hypotheses,
               :unresolved
             ]

      assert length(IR.fields()) == 13
    end
  end
end
