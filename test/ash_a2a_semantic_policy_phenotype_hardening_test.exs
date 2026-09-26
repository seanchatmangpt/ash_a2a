defmodule AshA2A.Semantic.PolicyPhenotypeHardeningTest do
  @moduledoc """
  Adversarial falsifiers for `AshA2A.Semantic.PolicyPhenotype` (ash_a2a#41).

  Every test drives the real module with real inputs and asserts on the real
  returned value or refusal; no collaborator is replaced. Each block names the
  attack it falsifies: disguised authority axes, malformed input that used to
  raise instead of refusing, duplicate delivery of one axis, smuggled
  authority-bearing options, tampered structs presented to `condition/2`, and
  replay/reordering determinism of the reaction-norm step.
  """
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.PolicyPhenotype
  alias AshA2A.Semantic.Refusal

  @cap "urn:sa2a:capability:Example.Search.read"

  defp base(extra \\ []) do
    [
      capability_iri: @cap,
      policy_family: "planner:Astar",
      conditionable_axes: %{"exploration" => %{min: 0.0, max: 1.0}}
    ] ++ extra
  end

  defp code({:error, %{code: code}}), do: code
  defp code(other), do: flunk("expected refusal, got #{inspect(other)}")

  describe "authority fence cannot be bypassed by spelling" do
    @disguised [
      "execution-grant",
      "Execution Grant",
      "execution.authority",
      "auth​ority",
      "perm­ission",
      "﻿do",
      "ＡＵＴＨＯＲＩＴＹ",
      "permissions",
      "grant_level",
      "initiative_authority",
      "lease",
      "credential",
      "  --DO--  ",
      :authority,
      :execution_grant,
      # camelCase / PascalCase / acronym boundaries (ash_a2a#41 court probe)
      "ExecutionGrant",
      "executionAuthority",
      "grantLevel",
      "AuthorityLevel",
      "doAction",
      "HTTPGrant",
      :executionGrant,
      # concatenations with no boundary at all
      "executiongrant",
      "executionauthority",
      "grantlevel",
      "preauthorized",
      "unpermitted",
      # plurals, participles, synonyms
      "leases",
      "tokens",
      "authorizations",
      "authorized",
      "authorized_level",
      "permitted",
      "privilege",
      "credentials_scope",
      "entitlement",
      # Cyrillic/Greek homoglyphs NFKC does not fold
      "\u0430uthority",
      "gr\u0430nt_level",
      "\u0440ermission",
      "p\u03B5rmit_scope",
      # not valid UTF-8: cannot be normalized, so the fence fails closed
      <<"authority", 0xFF>>,
      <<"execution_grant", 0x80>>,
      <<"exploration", 0xFF>>
    ]

    for axis <- @disguised do
      @axis axis
      test "refuses disguised authority axis #{inspect(axis)} with the authority code" do
        axis = @axis

        for opts <- [
              [conditionable_axes: %{axis => %{min: 0.0, max: 1.0}}],
              [
                conditionable_axes: %{
                  "exploration" => %{min: 0.0, max: 1.0},
                  axis => %{min: 0.0, max: 1.0}
                },
                reaction_norms: %{axis => %{slope: 1.0}}
              ]
            ] do
          result =
            PolicyPhenotype.new([capability_iri: @cap, policy_family: "planner:Astar"] ++ opts)

          assert {:error, %{code: :temperament_cannot_encode_authority, detail: ^axis}} = result
          assert Refusal.classify(code(result)) == :refused_authority
        end
      end
    end

    test "every default behavioral axis survives the fence (no false positives)" do
      axes = Map.new(PolicyPhenotype.default_axes(), &{&1, %{min: 0.0, max: 1.0}})

      assert {:ok, phenotype} =
               PolicyPhenotype.new(
                 capability_iri: @cap,
                 policy_family: "planner:Astar",
                 conditionable_axes: axes
               )

      assert map_size(phenotype.conditionable_axes) == length(PolicyPhenotype.default_axes())
    end

    test "ordinary words containing 'do' as a substring are not refused" do
      for axis <- ["domain_focus", "dormancy", "undo_tolerance", "domainFocus"] do
        assert {:ok, _} =
                 PolicyPhenotype.new(
                   capability_iri: @cap,
                   policy_family: "planner:Astar",
                   conditionable_axes: %{axis => %{min: 0.0, max: 1.0}}
                 )
      end
    end
  end

  describe "fence stays precise on ordinary behavioral names" do
    test "camelCase behavioral names and look-alike English words are admitted" do
      for axis <- [
            "selfModelPlasticity",
            "riskTolerance",
            "releaseCadence",
            "fragrant_novelty",
            "please_seeking",
            "Exploration_Level"
          ] do
        result =
          PolicyPhenotype.new(
            capability_iri: @cap,
            policy_family: "planner:Astar",
            conditionable_axes: %{axis => %{min: 0.0, max: 1.0}}
          )

        assert {:ok, _} = result, "false positive on #{inspect(axis)}"
      end
    end
  end

  describe "normalization fast path is equivalent to the Unicode reference" do
    # Reference implementation written independently in the test: the exact
    # regex pipeline the module uses for non-ASCII names. The ASCII fast path
    # must agree with it byte-for-byte on every ASCII input.
    defp reference(axis) do
      axis
      |> :unicode.characters_to_nfkc_binary()
      |> String.replace(~r/[\p{Cf}]/u, "")
      |> String.replace(~r/(?<=[\p{Ll}\p{N}])(?=\p{Lu})|(?<=\p{Lu})(?=\p{Lu}\p{Ll})/u, "_")
      |> String.downcase()
      |> String.replace(~r/[^\p{L}\p{N}]+/u, "_")
      |> String.trim("_")
    end

    test "exhaustive single/double-byte ASCII and a seeded random corpus agree" do
      singles = for c <- 0..127, do: <<c>>
      doubles = for a <- 0..127, b <- [?a, ?Z, ?_, ?-, ?\s, ?0], do: <<a, b>>
      triples = for a <- [?a, ?A, ?0, ?_], b <- [?A, ?b], c <- [?a, ?B, ?1, ?-], do: <<a, b, c>>

      :rand.seed(:exsss, {26, 9, 26})

      randoms =
        for _ <- 1..5_000 do
          len = :rand.uniform(24)
          for _ <- 1..len, into: <<>>, do: <<:rand.uniform(128) - 1>>
        end

      for axis <- singles ++ doubles ++ triples ++ randoms ++ PolicyPhenotype.default_axes() do
        assert PolicyPhenotype.normalize_axis_name(axis) == reference(axis),
               "fast path diverged on #{inspect(axis)}"
      end
    end

    test "non-ASCII names take the reference path" do
      for axis <- ["auth\u200Bority", "ＡＵＴＨＯＲＩＴＹ", "Éxploration", "perm\u00ADission"] do
        assert PolicyPhenotype.normalize_axis_name(axis) == reference(axis)
      end
    end

    test "invalid UTF-8 and non-string terms pass through unchanged" do
      assert PolicyPhenotype.normalize_axis_name(<<0xFF, 0xFE>>) == <<0xFF, 0xFE>>
      assert PolicyPhenotype.normalize_axis_name(42) == 42
      assert PolicyPhenotype.normalize_axis_name(:Execution_Grant) == "execution_grant"
    end

    test "camelCase and acronym boundaries split into tokens" do
      assert PolicyPhenotype.normalize_axis_name("ExecutionGrant") == "execution_grant"
      assert PolicyPhenotype.normalize_axis_name("executionAuthority") == "execution_authority"
      assert PolicyPhenotype.normalize_axis_name("HTTPGrant") == "http_grant"
      assert PolicyPhenotype.normalize_axis_name("v2Grant") == "v2_grant"
      assert PolicyPhenotype.normalize_axis_name("AUTHORITY") == "authority"
      assert PolicyPhenotype.normalize_axis_name("selfModelPlasticity") == "self_model_plasticity"
      assert PolicyPhenotype.normalize_axis_name("ÉxplorationLevel") == "éxploration_level"
    end

    test "a camelCase spelling collides with its snake_case twin" do
      assert {:error,
              %{
                code: :invalid_policy_phenotype,
                detail: {:duplicate_axis, :conditionable_axes, "self_model_plasticity"}
              }} =
               PolicyPhenotype.new(
                 capability_iri: @cap,
                 policy_family: "planner:Astar",
                 conditionable_axes: %{
                   "self_model_plasticity" => %{min: 0.0, max: 1.0},
                   "selfModelPlasticity" => %{min: 0.0, max: 1.0}
                 }
               )
    end
  end

  describe "smuggled authority-bearing options" do
    test "unknown options are refused rather than silently dropped" do
      for {key, value} <- [
            authority: :do,
            grant: "urn:grant:1",
            token: "secret",
            command_handle: make_ref()
          ] do
        assert {:error, %{code: :invalid_policy_phenotype, detail: {:unknown_option, ^key}}} =
                 PolicyPhenotype.new(base([{key, value}]))
      end
    end

    test "a duplicated option (second delivery) is refused, not last-wins" do
      opts = base(condition: %{"exploration" => 0.1}) ++ [condition: %{"exploration" => 0.9}]

      assert {:error, %{code: :invalid_policy_phenotype, detail: {:duplicate_option, :condition}}} =
               PolicyPhenotype.new(opts)
    end
  end

  describe "malformed input is refused, never raised" do
    test "non-enumerable axis maps" do
      for key <- [:conditionable_axes, :condition, :reaction_norms],
          bad <- ["exploration", 42, :atom, [1, 2], %URI{}] do
        opts = Keyword.put(base(), key, bad)

        assert {:error, %{code: :invalid_policy_phenotype, detail: {:expected_axis_map, ^key}}} =
                 PolicyPhenotype.new(opts)
      end
    end

    test "non-keyword list and non-list opts" do
      for bad <- [[1, 2], [{"capability_iri", @cap}], [{nil, 1}], %{capability_iri: @cap}, nil] do
        result = PolicyPhenotype.new(bad)
        assert code(result) == :invalid_policy_phenotype
        assert Refusal.classify(code(result)) == :refused_structure
      end
    end

    test "empty or non-binary identity" do
      for {iri, family} <- [{"", "planner:Astar"}, {@cap, ""}, {:cap, "p"}, {@cap, nil}] do
        assert {:error,
                %{code: :invalid_policy_phenotype, detail: :capability_and_policy_family_required}} =
                 PolicyPhenotype.new(
                   capability_iri: iri,
                   policy_family: family,
                   conditionable_axes: %{}
                 )
      end
    end

    test "degenerate or inverted ranges" do
      for range <- [%{min: 1.0, max: 1.0}, %{min: 1.0, max: 0.0}, %{min: "0", max: 1}, %{max: 1}] do
        assert {:error, %{code: :invalid_condition_axis_range}} =
                 PolicyPhenotype.new(
                   capability_iri: @cap,
                   policy_family: "planner:Astar",
                   conditionable_axes: %{"exploration" => range}
                 )
      end
    end

    test "condition values outside the declared range or non-numeric" do
      assert {:error, %{code: :condition_out_of_range}} =
               PolicyPhenotype.new(base(condition: %{"exploration" => 1.0000001}))

      assert {:error, %{code: :condition_out_of_range}} =
               PolicyPhenotype.new(base(condition: %{"exploration" => -0.1}))

      assert {:error, %{code: :invalid_policy_phenotype, detail: {:invalid_condition, _}}} =
               PolicyPhenotype.new(base(condition: %{"exploration" => "0.5"}))

      assert {:error, %{code: :unknown_condition_axis, detail: "sociability"}} =
               PolicyPhenotype.new(base(condition: %{"sociability" => 0.5}))
    end

    test "reaction norms with missing or non-numeric slope/reference cue" do
      for norm <- [%{}, %{slope: "1"}, %{slope: 1.0, reference_cue: :zero}, 1.0] do
        assert {:error, %{code: :invalid_reaction_norm}} =
                 PolicyPhenotype.new(base(reaction_norms: %{"exploration" => norm}))
      end
    end

    test "evidence refs must be non-empty strings" do
      for refs <- [[123], [""], ["urn:ok", :atom], %{a: 1}] do
        assert {:error, %{code: :invalid_policy_phenotype, detail: {:invalid_evidence_ref, _}}} =
                 PolicyPhenotype.new(base(evidence_refs: refs))
      end

      assert {:ok, %{evidence_refs: ["urn:evidence:one"]}} =
               PolicyPhenotype.new(base(evidence_refs: "urn:evidence:one"))

      assert {:ok, %{evidence_refs: []}} = PolicyPhenotype.new(base(evidence_refs: nil))
    end

    test "reaction arithmetic that overflows is refused, not raised" do
      for {norm, cue} <- [
            {%{slope: 1.0e308}, 1.0e10},
            {%{slope: -1.0e308}, 1.0e10},
            {%{slope: 1.0, reference_cue: -1.0e308}, 1.0e308},
            {%{slope: 10 ** 400}, 1.0}
          ] do
        {:ok, p} = PolicyPhenotype.new(base(reaction_norms: %{"exploration" => norm}))
        result = PolicyPhenotype.condition(p, cue)

        assert {:error, %{code: :invalid_reaction_norm, detail: {:overflow, "exploration", ^cue}}} =
                 result

        assert Refusal.classify(code(result)) == :refused_structure
      end
    end

    test "large but representable reaction arithmetic still clamps" do
      {:ok, p} = PolicyPhenotype.new(base(reaction_norms: %{"exploration" => %{slope: 1.0e300}}))
      assert {:ok, %{condition: %{"exploration" => 1.0}}} = PolicyPhenotype.condition(p, 1.0)
      assert {:ok, %{condition: %{"exploration" => low}}} = PolicyPhenotype.condition(p, -1.0)
      assert low == 0.0
    end

    test "non-numeric cue" do
      {:ok, p} = PolicyPhenotype.new(base())

      for cue <- ["1.0", nil, :high] do
        assert {:error, %{code: :invalid_policy_phenotype, detail: :cue_must_be_numeric}} =
                 PolicyPhenotype.condition(p, cue)
      end
    end
  end

  describe "duplicate delivery of one axis" do
    test "a pair list naming an axis twice is refused instead of last-wins" do
      assert {:error,
              %{
                code: :invalid_policy_phenotype,
                detail: {:duplicate_axis, :condition, "exploration"}
              }} =
               PolicyPhenotype.new(base(condition: [{"exploration", 0.1}, {"exploration", 0.9}]))
    end

    test "two spellings that normalize to one axis are refused as a collision" do
      assert {:error,
              %{
                code: :invalid_policy_phenotype,
                detail: {:duplicate_axis, :conditionable_axes, "exploration"}
              }} =
               PolicyPhenotype.new(
                 capability_iri: @cap,
                 policy_family: "planner:Astar",
                 conditionable_axes: %{
                   "exploration" => %{min: 0.0, max: 1.0},
                   "Exploration" => %{min: 0.0, max: 1.0}
                 }
               )
    end

    test "a pair list with distinct axes is accepted and equals the map form" do
      pairs = [{"exploration", 0.2}]
      assert {:ok, from_pairs} = PolicyPhenotype.new(base(condition: pairs))
      assert {:ok, from_map} = PolicyPhenotype.new(base(condition: Map.new(pairs)))
      assert from_pairs == from_map
    end
  end

  describe "tampered structs presented to condition/2 (stale or forged subject)" do
    setup do
      {:ok, p} =
        PolicyPhenotype.new(
          base(
            condition: %{"exploration" => 0.5},
            reaction_norms: %{"exploration" => %{slope: 0.5}}
          )
        )

      %{p: p}
    end

    test "authority axis injected after construction is refused", %{p: p} do
      forged = %{
        p
        | conditionable_axes: Map.put(p.conditionable_axes, "grant", %{min: 0, max: 1})
      }

      assert {:error, %{code: :temperament_cannot_encode_authority, detail: "grant"}} =
               PolicyPhenotype.condition(forged, 1.0)
    end

    test "identity stripped after construction is refused", %{p: p} do
      assert {:error, %{detail: :capability_and_policy_family_required}} =
               PolicyPhenotype.condition(%{p | capability_iri: nil}, 1.0)

      assert {:error, %{detail: :capability_and_policy_family_required}} =
               PolicyPhenotype.condition(%{p | policy_family: ""}, 1.0)
    end

    test "condition pushed out of range after construction is refused", %{p: p} do
      assert {:error, %{code: :condition_out_of_range}} =
               PolicyPhenotype.condition(%{p | condition: %{"exploration" => 7.0}}, 0.0)
    end

    test "non-string evidence injected after construction is refused", %{p: p} do
      assert {:error, %{detail: {:invalid_evidence_ref, 1}}} =
               PolicyPhenotype.condition(%{p | evidence_refs: [1]}, 0.0)
    end

    test "grant?/1 stays false even for a forged struct", %{p: p} do
      refute PolicyPhenotype.grant?(%{
               p
               | conditionable_axes: %{"authority" => %{min: 0, max: 1}}
             })
    end
  end

  describe "committed benchmark receipt is bound to its subject" do
    test "receipt names the exact blob of the module it measured" do
      subject_path = "lib/ash_a2a/semantic/policy_phenotype.ex"
      receipt = "receipts/v26.9.26/policy_phenotype_bench.json" |> File.read!() |> :json.decode()
      content = File.read!(subject_path)

      blob_sha1 =
        :crypto.hash(:sha, ["blob ", Integer.to_string(byte_size(content)), 0, content])
        |> Base.encode16(case: :lower)

      assert receipt["subject_path"] == subject_path

      assert receipt["subject_blob_sha1"] == blob_sha1,
             "benchmark receipt is stale: re-run with POLICY_PHENOTYPE_BENCH_RECEIPT=1"

      assert receipt["measured_on_parent"] =~ ~r/\A[0-9a-f]{40}\z/
    end
  end

  describe "replay and reordering determinism" do
    setup do
      axes = Map.new(PolicyPhenotype.default_axes(), &{&1, %{min: 0.0, max: 1.0}})

      norms =
        PolicyPhenotype.default_axes()
        |> Enum.with_index()
        |> Map.new(fn {axis, i} -> {axis, %{slope: (i - 4) / 10, reference_cue: 0.5}} end)

      condition = Map.new(PolicyPhenotype.default_axes(), &{&1, 0.5})

      %{axes: axes, norms: norms, condition: condition}
    end

    test "replaying the same cue sequence yields an identical phenotype", ctx do
      {:ok, p} =
        PolicyPhenotype.new(
          capability_iri: @cap,
          policy_family: "planner:MCTS",
          conditionable_axes: ctx.axes,
          condition: ctx.condition,
          reaction_norms: ctx.norms
        )

      cues = [0.0, 1.0, 0.25, -3.0, 9.0, 0.5]

      run = fn ->
        Enum.reduce(cues, p, fn cue, acc -> elem(PolicyPhenotype.condition(acc, cue), 1) end)
      end

      first = run.()
      assert first == run.()
      assert :erlang.term_to_binary(first) == :erlang.term_to_binary(run.())
      assert first.capability_iri == p.capability_iri
      assert first.policy_family == p.policy_family
      assert Map.keys(first.conditionable_axes) == Map.keys(p.conditionable_axes)

      for {axis, value} <- first.condition do
        assert value >= 0.0 and value <= 1.0, "#{axis} escaped its range: #{value}"
      end
    end

    test "declaration order of axes and norms does not change the result", ctx do
      forward = fn m -> m |> Enum.sort() end
      reverse = fn m -> m |> Enum.sort() |> Enum.reverse() end

      results =
        for order <- [forward, reverse] do
          {:ok, p} =
            PolicyPhenotype.new(
              capability_iri: @cap,
              policy_family: "planner:MCTS",
              conditionable_axes: order.(ctx.axes),
              condition: order.(ctx.condition),
              reaction_norms: order.(ctx.norms)
            )

          {:ok, conditioned} = PolicyPhenotype.condition(p, 0.8)
          conditioned
        end

      assert [same, same] = results
    end

    test "clamping is idempotent at the bounds for extreme cues", ctx do
      {:ok, p} =
        PolicyPhenotype.new(
          capability_iri: @cap,
          policy_family: "planner:MCTS",
          conditionable_axes: ctx.axes,
          reaction_norms: ctx.norms
        )

      {:ok, hi} = PolicyPhenotype.condition(p, 1.0e12)
      {:ok, hi2} = PolicyPhenotype.condition(hi, 1.0e12)
      assert hi.condition == hi2.condition
      assert Enum.all?(Map.values(hi.condition), &(&1 in [0.0, 1.0]))
    end
  end
end
