defmodule AshA2A.Semantic.SelectTest do
  @moduledoc """
  RFC-SA2A-001 S25: SELECT chooses among lawful possibilities and MUST NOT
  perform consequential external mutation.

  The "no consequential external mutation" claim is checked against the
  **real compiled BEAM's own import table** (`:beam_lib.chunks(beam,
  [:imports])`), not against a grep of the source and not against a mock
  that records calls. The import table is the exhaustive list of external
  functions the module's compiled code can call; a module whose import table
  contains no `AshA2A.CommandBus` entry provably cannot reach the
  consequence boundary, whatever its source looks like.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{PlanPackage, Select}
  alias AshA2A.Test.SA2APlanFixture, as: Fixture

  defp package(overrides) do
    {projection, _ontology} = Fixture.projection()

    {:ok, pkg} =
      PlanPackage.from_projection(projection, "planner", Fixture.strict_opts(overrides))

    pkg
  end

  # Real module-level structural fact, read out of the compiled .beam file on
  # disk. Returns the list of `{module, function, arity}` this module's
  # compiled code can call externally.
  defp imports(module) do
    path = :code.which(module)
    {:ok, {^module, [imports: imports]}} = :beam_lib.chunks(path, [:imports])
    imports
  end

  defp imported_modules(module) do
    module |> imports() |> Enum.map(fn {mod, _fun, _arity} -> mod end) |> Enum.uniq()
  end

  describe "S25 -- SELECT performs no consequential external mutation" do
    test "the compiled module's real import table reaches no consequence boundary" do
      modules = imported_modules(Select)

      # Sanity: the check is capable of seeing anything at all.
      assert AshA2A.Semantic.PlanPackage in modules

      forbidden = [
        AshA2A.CommandBus,
        AshA2A.ReceiptStore,
        AshA2A.ReceiptOutbox,
        AshA2A.Receipt,
        AshA2A.Authority,
        AshA2A.KillSwitch,
        Ash,
        Ecto.Repo,
        :file,
        :os
      ]

      assert Enum.filter(forbidden, &(&1 in modules)) == []
    end

    test "the module exposes no DO-shaped function at all" do
      exported = Select.__info__(:functions) |> Keyword.keys() |> Enum.uniq()

      for banned <- [:execute, :run, :dispatch, :do_select, :commit, :apply_plan] do
        refute banned in exported
      end

      assert :select in exported
    end

    test "a selection is candidate-standing and authority-free" do
      packages = [package(max_depth: 3), package(max_depth: 4)]
      assert {:ok, selection} = Select.select(packages, & &1.max_depth)

      assert selection.standing == :candidate
      assert selection.authority == :none
      refute Map.has_key?(selection, :authority_grant)
    end
  end

  describe "choosing among lawful possibilities" do
    test "the lowest-cost candidate wins and the rest are recorded as rejected" do
      cheap = package(max_depth: 2)
      mid = package(max_depth: 5)
      dear = package(max_depth: 9)

      assert {:ok, selection} =
               Select.select([dear, cheap, mid], & &1.max_depth,
                 selector_identity: "test-selector"
               )

      assert selection.chosen.max_depth == 2
      assert selection.chosen_digest == cheap.plan_digest

      assert selection.considered_digests == [
               cheap.plan_digest,
               mid.plan_digest,
               dear.plan_digest
             ]

      assert selection.rejected_digests == [mid.plan_digest, dear.plan_digest]
      assert selection.selector_identity == "test-selector"
      assert selection.selection_digest =~ ~r/\Asha256:[0-9a-f]{64}\z/
    end

    test "selection is deterministic regardless of the order candidates arrive in" do
      a = package(max_depth: 3)
      b = package(max_depth: 7)
      c = package(max_fan_out: 2, max_depth: 3)

      # a and c tie on the scorer; the plan_digest tie-break is order-free.
      {:ok, one} = Select.select([a, b, c], & &1.max_depth)
      {:ok, two} = Select.select([c, b, a], & &1.max_depth)
      {:ok, three} = Select.select([b, c, a], & &1.max_depth)

      assert one.chosen_digest == two.chosen_digest
      assert two.chosen_digest == three.chosen_digest
      assert one.selection_digest == two.selection_digest
      assert two.selection_digest == three.selection_digest
    end

    test "a selection over a different candidate set is distinguishable even when it chose the same package" do
      winner = package(max_depth: 1)
      other = package(max_depth: 4)

      {:ok, narrow} = Select.select([winner], & &1.max_depth)
      {:ok, wide} = Select.select([winner, other], & &1.max_depth)

      assert narrow.chosen_digest == wide.chosen_digest
      refute narrow.selection_digest == wide.selection_digest
    end

    test "an empty candidate set is refused" do
      assert {:error, %{code: :selection_no_candidates}} = Select.select([], & &1.max_depth)
    end

    test "a tampered candidate refuses the whole selection, naming its index" do
      good = package(max_depth: 2)
      tampered = %{package(max_depth: 3) | max_depth: 999}

      assert {:error, %{code: :selection_candidate_unverifiable, detail: detail}} =
               Select.select([good, tampered], & &1.max_depth)

      assert detail.index == 1
      assert detail.refusal.code == :plan_package_manual_edit_not_canonical
    end

    test "a non-numeric scorer result is a typed refusal, not a crash" do
      assert {:error, %{code: :selection_scorer_invalid, detail: detail}} =
               Select.select([package(max_depth: 2)], fn _pkg -> :cheap end)

      assert detail.returned == :cheap
    end

    test "a strict receiver refuses to select among permissively-built plans" do
      {projection, _ontology} = Fixture.projection()

      {:ok, loose} =
        PlanPackage.from_projection(
          projection,
          "planner",
          Fixture.strict_opts(profile: :permissive, max_parallelism: nil)
        )

      # Without a profile demand, the loose plan is selectable.
      assert {:ok, _selection} = Select.select([loose], fn _pkg -> 1 end)

      # With one, it is refused -- and the refusal names which candidate.
      assert {:error, %{code: :selection_candidate_profile_violation, detail: detail}} =
               Select.select([loose], fn _pkg -> 1 end, profile: :strict)

      assert detail.index == 0
      assert detail.profile == :strict
      assert :max_parallelism in detail.refusal.detail.missing
    end
  end
end
