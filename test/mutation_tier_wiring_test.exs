# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.MutationTierWiringTest do
  @moduledoc """
  The exhaustive mutation matrix is tagged `:mutation_catalog_full` and is
  excluded from the default tiers. A tag exclusion can hide tests silently, so
  this test pins the wiring: the alias that runs the tag, the default aliases
  that exclude it, the proofs workflow that runs it (and the CLI gate), and that
  the matrix and the CLI cover the same catalog ids.
  """

  use ExUnit.Case, async: true

  @root Path.expand("..", __DIR__)
  @tag_name "mutation_catalog_full"

  defp aliases, do: AshA2A.MixProject.project()[:aliases]
  defp read(path), do: File.read!(Path.join(@root, path))

  test "mix test.mutation exists and runs only the full-catalog tag" do
    assert aliases()[:"test.mutation"] == "test --only #{@tag_name}"
    assert AshA2A.MixProject.cli()[:preferred_envs][:"test.mutation"] == :test
  end

  test "every default tier excludes the full-catalog tag" do
    for name <- [:test, :"test.all", :"test.serial", :"test.serial.shard", :"test.serial.solo"] do
      assert aliases()[name] =~ "--exclude #{@tag_name}",
             "#{name} no longer excludes :#{@tag_name}; the full matrix would run in that tier"
    end

    refute aliases()[:"test.all"] =~ "--include #{@tag_name}"
  end

  test "proofs.yml runs both the CLI gate and the full-catalog test alias" do
    proofs = read(".github/workflows/proofs.yml")
    assert proofs =~ ~r/run: mix ash_a2a\.chicago\.mutate .*--require-killed/
    assert proofs =~ ~r/run: mix test\.mutation\s*$/m
  end

  test "the tagged tests carry no tier tag that could re-include them" do
    # ExUnit lets --include/--only win over --exclude: a module-level :serial
    # would run the full matrix again in `mix test.all`.
    for file <- [
          "test/ash_a2a/chicago/mutation_harness_test.exs",
          "test/mutation_wave3_catalog_test.exs"
        ] do
      src = read(file)
      refute src =~ ~r/@moduletag :serial/, "#{file} has a module-level serial tier tag"
      assert src =~ "@describetag :#{@tag_name}"
    end
  end

  test "the full matrix and the CLI gate cover the same catalog ids" do
    alias AshA2A.Chicago.Courts.MutationCourt
    alias AshA2A.Chicago.Mutation.Catalog

    # CLI: `Catalog.entries/0` (selected/1). Matrix: one falsifier per
    # `Catalog.numbered/0` entry in the harness test, and every wave-3 id.
    cli = read("lib/mix/tasks/ash_a2a.chicago.mutate.ex")
    assert cli =~ "Enum.filter(Catalog.entries()"

    court_ids = Enum.map(MutationCourt.falsifiers(), & &1.id)
    numbered = Enum.map(Catalog.numbered(), &elem(&1, 0))
    assert numbered -- court_ids == []
    assert length(numbered) == length(Catalog.ids())

    wave3 = read("test/mutation_wave3_catalog_test.exs")
    ids = Regex.scan(~r/^\s+"([a-z0-9_]+)" => ~w\(/m, wave3) |> Enum.map(&List.last/1)
    assert ids != []
    assert ids -- Catalog.ids() == []
    # Every wave-3 id is in the catalog (checked above); the catalog may also hold
    # mutants other lanes added, so it can be larger than 19 + wave-3.
    assert length(ids) <= length(Catalog.entries()) - 19
  end
end
