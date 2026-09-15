defmodule AshA2A.BoardPersona.DeliberationTest do
  @moduledoc """
  Chicago-style: every `generate_object`/`plan_generate_object` seam here is
  a real anonymous function producing fixed, schema-valid output (the same
  real DI seam `test/ash_a2a/semantic_compiler_test.exs` already
  establishes) -- a live network LLM call is not viable to run
  deterministically in CI for the seam-based tests below. Every step
  downstream of that seam (IR construction, real Admission fencing, real
  Ontology/PlanningIR projection, and -- the property these tests exist to
  prove -- real capability-id resolution against each persona's OWN real,
  independently-compiled `AshA2A.Info.capability_index/1` via
  `AshA2A.Planning.admit/2`) executes for real, with no further test
  doubles. No Mock/mox/patch/monkeypatch anywhere in this file.

  The one exception, clearly separated below and tagged `:external_api`, is
  a real, unseamed end-to-end test against the live Z.AI endpoint, matching
  the exact precedent already established in
  `test/ash_a2a_freedom_gym_zai_test.exs` / `test/ash_a2a_agent_semantic_request_test.exs`
  (same `~/.env` key read, same named/visible skip when the key is absent,
  same `@tag timeout:` discipline).
  """

  use ExUnit.Case, async: true

  alias AshA2A.BoardPersona.{ActivistPressured, Deliberation, GrowthFocusedFounderLed}
  alias AshA2A.BoardPersona.RiskAverseFiduciary
  alias AshA2A.Planning.SemanticSynthesis
  alias AshA2A.Semantic.{ExecutionPackage, IR}

  @scenario_text "The board must decide whether to proceed with the proposed plan."

  # See `AshA2A.Test.EnvKeyFixture`'s moduledoc for why this compile-time
  # extraction calls a shared *external* support module rather than a local
  # `defp` (a local call would fail to compile at this point). `setup_all`
  # cannot live inside a `describe` block (ExUnit refuses that at compile
  # time), so it and this module attribute are declared here, at module
  # top-level, even though only the one `:external_api`-tagged test below
  # actually depends on the key -- installing it is a harmless no-op for
  # every other (seam-based) test in this module.
  @zai_key AshA2A.Test.EnvKeyFixture.read_key("Z_AI_API_KEY")

  setup_all do
    if @zai_key do
      Application.put_env(:req_llm, :zai_coder_api_key, @zai_key)
    end

    :ok
  end

  describe "personas/0" do
    test "returns exactly the 3 real persona resource modules, in fan-out order" do
      assert Deliberation.personas() == [
               RiskAverseFiduciary,
               GrowthFocusedFounderLed,
               ActivistPressured
             ]
    end
  end

  describe "deliberate/2 (seam-based, real capability admission)" do
    test "fans out one scenario across all 3 personas and admits a real, distinct capability per persona's own closed set" do
      extract = fn _model_spec, _prompt, _schema, _llm_opts -> {:ok, extraction()} end

      # Real, structural discrimination: which persona a given synthesis call
      # is for is read off the real closed `capability_ids` enum the real
      # pipeline built for THAT persona (`SemanticSynthesis.output_schema/1`)
      # -- never guessed from prompt text. `:defer_decision` only exists on
      # `RiskAverseFiduciary`'s real action set; `:escalate_to_shareholder_vote`
      # only on `ActivistPressured`'s; whichever is left is
      # `GrowthFocusedFounderLed`.
      plan = fn _model_spec, _prompt, schema, _llm_opts ->
        enum = get_in(schema, ["properties", "capability_ids", "items", "enum"]) || []

        chosen =
          cond do
            Enum.any?(enum, &String.ends_with?(&1, ".defer_decision")) ->
              Enum.find(enum, &String.ends_with?(&1, ".reject"))

            Enum.any?(enum, &String.ends_with?(&1, ".escalate_to_shareholder_vote")) ->
              Enum.find(enum, &String.ends_with?(&1, ".escalate_to_shareholder_vote"))

            true ->
              Enum.find(enum, &String.ends_with?(&1, ".approve"))
          end

        {:ok,
         %{
           "request_id" => "deliberation-plan-#{System.unique_integer([:positive])}",
           "authority" => "none",
           "capability_ids" => [chosen],
           "hddl" => "(:task board-decision)",
           "fond" => "(:policy observe-or-replan)"
         }}
      end

      assert %{results: results, split: split} =
               Deliberation.deliberate(@scenario_text,
                 generate_object: extract,
                 plan_generate_object: plan
               )

      assert Map.keys(results) |> Enum.sort() == Enum.sort(Deliberation.personas())

      assert {:ok, %ExecutionPackage{standing: :candidate, authority: :none} = risk_pkg} =
               results[RiskAverseFiduciary]

      assert risk_pkg.plan_candidate.capability_ids == [
               "AshA2A.BoardPersona.RiskAverseFiduciary.reject"
             ]

      assert {:ok, %ExecutionPackage{standing: :candidate, authority: :none} = growth_pkg} =
               results[GrowthFocusedFounderLed]

      assert growth_pkg.plan_candidate.capability_ids == [
               "AshA2A.BoardPersona.GrowthFocusedFounderLed.approve"
             ]

      assert {:ok, %ExecutionPackage{standing: :candidate, authority: :none} = activist_pkg} =
               results[ActivistPressured]

      assert activist_pkg.plan_candidate.capability_ids == [
               "AshA2A.BoardPersona.ActivistPressured.escalate_to_shareholder_vote"
             ]

      # Real, honestly counted: 1 real approve-shaped admission
      # (GrowthFocusedFounderLed's bare :approve), 2 real non-approve-shaped
      # admissions (RiskAverseFiduciary's :reject, ActivistPressured's
      # :escalate_to_shareholder_vote), 0 errors -- no fabricated consensus
      # score, just the real counted facts about what each persona's real
      # synthesis actually admitted.
      assert split == %{approve_shaped: 1, other: 2, errored: 0}
    end

    test "risk-averse fiduciary's real closed capability set structurally refuses a bare :approve id even when the model proposes it" do
      extract = fn _model_spec, _prompt, _schema, _llm_opts -> {:ok, extraction()} end

      # No `:approve` action exists anywhere on
      # `AshA2A.BoardPersona.RiskAverseFiduciary` (see its own moduledoc) --
      # this fixture simulates a model that (incorrectly) proposes one
      # anyway, discriminated (same real, structural `:defer_decision`/
      # `:escalate_to_shareholder_vote` enum check the differentiation test
      # above uses) so only the risk-averse persona's call receives the bad
      # proposal -- the other two personas get a real, valid capability from
      # their own closed set, isolating the refusal to exactly one slot. The
      # real `AshA2A.Info.skill/2` lookup inside `AshA2A.Planning.admit/2`
      # (not this test, not this fixture) is what refuses the bad one: this
      # is not a schema-enum trick the fixture is cooperating with, it's the
      # real, independent capability-index resolution failing closed.
      plan = fn _model_spec, _prompt, schema, _llm_opts ->
        enum = get_in(schema, ["properties", "capability_ids", "items", "enum"]) || []

        chosen_ids =
          cond do
            Enum.any?(enum, &String.ends_with?(&1, ".defer_decision")) ->
              ["AshA2A.BoardPersona.RiskAverseFiduciary.approve"]

            Enum.any?(enum, &String.ends_with?(&1, ".escalate_to_shareholder_vote")) ->
              [Enum.find(enum, &String.ends_with?(&1, ".escalate_to_shareholder_vote"))]

            true ->
              [Enum.find(enum, &String.ends_with?(&1, ".approve"))]
          end

        {:ok,
         %{
           "request_id" => "forced-approve-#{System.unique_integer([:positive])}",
           "authority" => "none",
           "capability_ids" => chosen_ids,
           "hddl" => "(:task board-decision)",
           "fond" => "(:policy observe-or-replan)"
         }}
      end

      assert %{results: results, split: split} =
               Deliberation.deliberate(@scenario_text,
                 generate_object: extract,
                 plan_generate_object: plan
               )

      assert {:error, %{code: :noncanonical_capability, detail: capability_id}} =
               results[RiskAverseFiduciary]

      assert capability_id == "AshA2A.BoardPersona.RiskAverseFiduciary.approve"

      assert {:ok, %ExecutionPackage{}} = results[GrowthFocusedFounderLed]
      assert {:ok, %ExecutionPackage{}} = results[ActivistPressured]

      assert split == %{approve_shaped: 1, other: 1, errored: 1}
    end

    test "an admission failure at one persona is isolated to that persona's own slot" do
      # Ungrounded: the "source_quote" below is not verbatim present in
      # `@scenario_text`, so the real `Admission.validate_item/3` grounding
      # check refuses it for every persona (same real gate regardless of
      # which persona's resource is compiling) -- proving isolation, not
      # differentiated admission logic per se.
      extract = fn _model_spec, _prompt, _schema, _llm_opts ->
        {:ok,
         IR.fields()
         |> Map.new(&{Atom.to_string(&1), []})
         |> Map.put("authority", "none")
         |> Map.put("goals", [
           %{
             "id" => "ungrounded-goal",
             "kind" => "goal",
             "description" => "a goal not actually in the source",
             "source_quote" => "this text does not appear in the scenario at all"
           }
         ])}
      end

      plan = fn _model_spec, _prompt, _schema, _llm_opts ->
        flunk("plan_generate_object should never be reached -- admission fails before synthesis")
      end

      assert %{results: results, split: split} =
               Deliberation.deliberate(@scenario_text,
                 generate_object: extract,
                 plan_generate_object: plan
               )

      assert Enum.all?(results, fn {_persona, result} ->
               match?({:error, %{code: :ungrounded_assertion}}, result)
             end)

      assert split == %{approve_shaped: 0, other: 0, errored: 3}
    end
  end

  describe "real, unseamed end-to-end (live Z.AI, gated behind --include external_api)" do
    # 3 real personas x 2 real sequential LLM round-trips each (extraction,
    # then synthesis), run concurrently across personas via
    # `Deliberation.deliberate/2`'s own real `Task.async_stream/3` -- bounded
    # by the slowest single persona's own 2-call chain, not 3x that, but
    # given the real rate-limit contention already documented and disclosed
    # in `test/ash_a2a_agent_semantic_request_test.exs` and
    # `test/ash_a2a_freedom_gym_zai_test.exs`, the same generous real-world
    # timeout precedent is used here rather than a fresh guess.
    @tag :external_api
    @tag timeout: 240_000
    @tag skip: is_nil(@zai_key) && "Z_AI_API_KEY not found in ~/.env"
    test "a real live 3-way persona fan-out completes end to end with typed, structurally-admitted results" do
      assert %{results: results, split: split} = Deliberation.deliberate(@scenario_text)

      assert Map.keys(results) |> Enum.sort() == Enum.sort(Deliberation.personas())

      Enum.each(results, fn {persona, result} ->
        case result do
          {:ok, %ExecutionPackage{standing: :candidate, authority: :none} = package} ->
            # Real structural check: every admitted capability id is drawn
            # from THIS persona's own real, independently-derived closed
            # set -- never another persona's, and never a live model's own
            # unverified claim (re-derived here from the real compiled
            # capability index, the same source `AshA2A.Planning.admit/2`
            # itself checks against).
            closed_set = SemanticSynthesis.capability_ids(persona)

            assert Enum.all?(package.plan_candidate.capability_ids, &(&1 in closed_set)),
                   "persona #{inspect(persona)} admitted a capability id outside its own closed set: #{inspect(package.plan_candidate.capability_ids)} not subset of #{inspect(closed_set)}"

          {:error, reason} ->
            # A real, typed refusal (e.g. real grounding failure against a
            # live model's own phrasing) is a legitimate real outcome here,
            # same as the existing `:external_api` precedent tests -- never
            # a crash/exception escaping `Deliberation.deliberate/2`.
            assert is_map(reason) or is_tuple(reason)
        end
      end)

      assert split.approve_shaped + split.other + split.errored == 3
    end
  end

  defp extraction do
    IR.fields()
    |> Map.new(&{Atom.to_string(&1), []})
    |> Map.put("authority", "none")
    |> Map.put("goals", [
      %{
        "id" => "scenario-goal",
        "kind" => "goal",
        "description" => "decide whether to proceed with the plan",
        "source_quote" => @scenario_text
      }
    ])
  end
end
