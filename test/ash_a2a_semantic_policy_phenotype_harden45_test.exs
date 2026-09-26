defmodule AshA2A.Semantic.PolicyPhenotypeHarden45Test do
  @moduledoc """
  Second-court falsifiers for `AshA2A.Semantic.PolicyPhenotype` (ash_a2a#45
  @ 67f48618). Every test drives the real module with real inputs and asserts
  on the real returned value or refusal; nothing is replaced.

  Defects this file killed (each admitted or raised on 67f48618):

    * H1 interior split: a forbidden token or affix root split across token
      boundaries in the middle of a name (`boldness_gr_ant_level`,
      `d_o_action`, `x_to_ken_budget`) was admitted, while the unsplit
      spelling was refused.
    * H2 digit-for-letter spellings (`auth0rity`, `gr4nt_level`, `l3ase`,
      `permi55ion`) were admitted.
    * H3 Latin dotless i / Latin alpha look-alikes (`authorıty`) were admitted.
    * H4 `admin` spellings were admitted beside `sudo`/`superuser`.
    * H5 a struct with a non-map axis field presented to `condition/2` raised
      BadMapError instead of refusing.
    * H6 improper lists (options, pair lists, evidence refs) raised
      FunctionClauseError instead of refusing.
    * H7 `condition/2` on a non-phenotype raised FunctionClauseError.
  """
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.PolicyPhenotype
  alias AshA2A.Semantic.Refusal

  @cap "urn:sa2a:capability:Example.Search.read"

  defp opts(axis, extra \\ []) do
    [
      capability_iri: @cap,
      policy_family: "planner:MCTS",
      conditionable_axes: %{axis => %{min: 0.0, max: 1.0}}
    ] ++ extra
  end

  defp code({:error, %{code: code}}), do: code
  defp code({:ok, _}), do: :ADMITTED

  # Roots whose unsplit spelling the fence refuses; each must stay refused
  # however it is split, and wherever in the name it sits.
  @roots ["grant", "lease", "token", "do", "sudo", "admin", "authority", "permission"]

  defp splits(root) do
    n = String.length(root)

    two = for i <- 1..(n - 1)//1, do: [String.slice(root, 0, i), String.slice(root, i..-1//1)]

    three =
      for i <- 1..(n - 2)//1, j <- (i + 1)..(n - 1)//1 do
        [String.slice(root, 0, i), String.slice(root, i, j - i), String.slice(root, j..-1//1)]
      end

    two ++ three
  end

  describe "H1 a root split across interior token boundaries is refused" do
    test "every 2- and 3-way split of every root, at the start, middle and end of a name" do
      for root <- @roots, parts <- splits(root), sep <- ["_", "-", " "] do
        split = Enum.join(parts, sep)

        for axis <- [split, "boldness_" <> split <> "_level", "boldness_" <> split] do
          assert code(PolicyPhenotype.new(opts(axis))) == :temperament_cannot_encode_authority,
                 "admitted split root #{inspect(axis)}"
        end
      end
    end

    test "the named 67f48618 escapes are refused with the authority code" do
      for axis <- [
            "boldness_gr_ant_level",
            "d_o_action",
            "x_to_ken_budget",
            "yyyyyyyyyyyyyyyyyyyygra_nt_level",
            "exploration_le_ase_window",
            "initiativeGrAnt"
          ] do
        result = PolicyPhenotype.new(opts(axis))

        assert {:error, %{code: :temperament_cannot_encode_authority, detail: ^axis}} = result
        assert Refusal.classify(:temperament_cannot_encode_authority) == :refused_authority
      end
    end

    test "a split root nested as a key inside a range is refused as an unknown option" do
      range = %{min: 0.0, max: 1.0, gr_ant_level: 1}

      assert {:error,
              %{code: :invalid_policy_phenotype, detail: {:unknown_option, :gr_ant_level}}} =
               PolicyPhenotype.new(
                 capability_iri: @cap,
                 policy_family: "planner:MCTS",
                 conditionable_axes: %{"boldness" => range}
               )
    end
  end

  describe "H2/H3/H4 look-alike spellings are refused" do
    test "digit-for-letter spellings" do
      for axis <- [
            "auth0rity",
            "gr4nt_level",
            "permi55ion",
            "l3ase",
            "t0ken_budget",
            "pr1vilege",
            "privi1ege",
            "cr3dential",
            "d0_action",
            "4dmin"
          ] do
        assert code(PolicyPhenotype.new(opts(axis))) == :temperament_cannot_encode_authority,
               "admitted #{inspect(axis)}"
      end
    end

    test "Latin dotless i and Latin alpha look-alikes" do
      for axis <- ["authorıty", "grɑnt_level", "ɑdmin"] do
        assert code(PolicyPhenotype.new(opts(axis))) == :temperament_cannot_encode_authority,
               "admitted #{inspect(axis)}"
      end
    end

    test "admin spellings" do
      for axis <- ["admin", "admin_level", "adm_in", "Administrator", "boldnessAdmins"] do
        assert code(PolicyPhenotype.new(opts(axis))) == :temperament_cannot_encode_authority,
               "admitted #{inspect(axis)}"
      end
    end
  end

  describe "the widened fence keeps ordinary behavioral names" do
    test "default axes, numbered axes and look-alike English words are admitted" do
      for axis <-
            PolicyPhenotype.default_axes() ++
              [
                "exploration_2",
                "tier3_boldness",
                "phase_10_activity",
                "boldness_v2",
                "undo_tolerance",
                "domain_focus",
                "dormancy",
                "fragrant_novelty",
                "releaseCadence",
                "please_seeking",
                "selfModelPlasticity",
                "risk_tolerance",
                "go_to_goal"
              ] do
        assert {:ok, _} = PolicyPhenotype.new(opts(axis)), "false positive on #{inspect(axis)}"
      end
    end

    test "the full default vocabulary with norms still conditions" do
      axes = PolicyPhenotype.default_axes()

      assert {:ok, p} =
               PolicyPhenotype.new(
                 capability_iri: @cap,
                 policy_family: "planner:MCTS",
                 conditionable_axes: Map.new(axes, &{&1, %{min: 0.0, max: 1.0}}),
                 reaction_norms: Map.new(axes, &{&1, %{slope: 0.1}})
               )

      assert {:ok, q} = PolicyPhenotype.condition(p, 2.0)
      assert Enum.all?(q.condition, fn {_axis, v} -> v >= 0.0 and v <= 1.0 end)
    end
  end

  describe "the window check is bounded on adversarial lengths" do
    test "a 10_000-token benign name is decided (admitted) without quadratic blow-up" do
      axis = List.duplicate("a", 10_000) |> Enum.join("_")
      {us, result} = :timer.tc(fn -> PolicyPhenotype.new(opts(axis)) end)
      assert {:ok, _} = result
      # linear: 10_000 tokens x 14 windows; a quadratic window scan is ~5e7 joins
      assert us < 2_000_000, "10_000-token name took #{us}us"
    end

    test "a split root at the far end of a long name is still refused" do
      axis = (List.duplicate("a", 5_000) |> Enum.join("_")) <> "_gr_ant"
      assert code(PolicyPhenotype.new(opts(axis))) == :temperament_cannot_encode_authority
    end
  end

  describe "H5/H7 malformed subjects handed to condition/2 are refused, never raised" do
    setup do
      {:ok, p} =
        PolicyPhenotype.new(
          capability_iri: @cap,
          policy_family: "planner:MCTS",
          conditionable_axes: %{"boldness" => %{min: 0.0, max: 1.0}},
          reaction_norms: %{"boldness" => %{slope: 0.5}}
        )

      %{p: p}
    end

    test "non-map axis containers", %{p: p} do
      for {field, value} <- [
            conditionable_axes: [1],
            conditionable_axes: nil,
            condition: nil,
            condition: "boldness",
            reaction_norms: 5,
            reaction_norms: MapSet.new(["boldness"])
          ] do
        forged = Map.put(p, field, value)

        assert {:error, %{code: :invalid_policy_phenotype, detail: {:expected_axis_map, ^field}}} =
                 PolicyPhenotype.condition(forged, 0.5)
      end
    end

    test "non-list or improper evidence refs", %{p: p} do
      for refs <- [:evidence, "urn:e", ["urn:e" | :tail]] do
        assert {:error, %{code: :invalid_policy_phenotype, detail: {:invalid_evidence_ref, _}}} =
                 PolicyPhenotype.condition(%{p | evidence_refs: refs}, 0.5)
      end
    end

    test "a non-phenotype first argument" do
      for subject <- [nil, %{}, %{capability_iri: @cap}, "phenotype", 42, %URI{}] do
        assert {:error, %{code: :invalid_policy_phenotype, detail: :expected_policy_phenotype}} =
                 PolicyPhenotype.condition(subject, 0.5)
      end
    end

    test "the untouched phenotype still conditions after the forgeries", %{p: p} do
      assert {:ok, q} = PolicyPhenotype.condition(p, 1.0)
      assert q.condition == %{"boldness" => 0.5}
    end
  end

  describe "H6 improper lists are refused, never raised" do
    test "improper option list" do
      assert {:error, %{code: :invalid_policy_phenotype, detail: :expected_keyword_list}} =
               PolicyPhenotype.new([{:capability_iri, @cap} | :tail])
    end

    test "improper pair list for an axis field" do
      assert {:error,
              %{
                code: :invalid_policy_phenotype,
                detail: {:expected_axis_map, :conditionable_axes}
              }} =
               PolicyPhenotype.new(
                 capability_iri: @cap,
                 policy_family: "planner:MCTS",
                 conditionable_axes: [{"boldness", %{min: 0.0, max: 1.0}} | :tail]
               )
    end

    test "improper evidence ref list" do
      assert {:error, %{code: :invalid_policy_phenotype, detail: {:invalid_evidence_ref, _}}} =
               PolicyPhenotype.new(opts("boldness", evidence_refs: ["urn:e" | :tail]))
    end
  end
end
