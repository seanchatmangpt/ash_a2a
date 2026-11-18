# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SecurityMutationWitnessTest do
  @moduledoc """
  Every security gate (owner scope, forged identity, :strict boot refusals,
  authority_policy, ReceiptStore.boot_check) has a mutation catalog entry that
  names the court that must flip. Read-only: builds mutant plans
  (`Mutation.prepare/1`) but never hot-loads one, so it is safe under async.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Chicago.Mutation
  alias AshA2A.Chicago.Mutation.Catalog

  @root Path.expand("..", __DIR__)

  defp entries_for(module, function, arity) do
    Enum.filter(
      Catalog.entries(),
      &(&1.module == module and &1.function == function and &1.arity == arity)
    )
  end

  test "every security gate has at least one catalog entry" do
    for {gate, module, function, arity} <- Catalog.security_gates() do
      assert entries_for(module, function, arity) != [],
             "security gate #{inspect(gate)} (#{inspect(module)}.#{function}/#{arity}) has no mutation entry"
    end
  end

  test "every security entry names a killer family and an on-disk ExUnit court" do
    for {gate, module, function, arity} <- Catalog.security_gates(),
        m <- entries_for(module, function, arity) do
      assert m.killers != [], "#{gate}/#{m.id}: no killers named"
      assert is_binary(m.guard) and m.guard != "", "#{gate}/#{m.id}: no guard text"
      assert is_binary(m.description), "#{gate}/#{m.id}: no court description"

      paths = Regex.scan(~r{test/[\w/\.]+\.exs}, m.description) |> List.flatten()
      assert paths != [], "#{gate}/#{m.id}: description names no court file"

      for p <- paths do
        assert File.exists?(Path.join(@root, p)), "#{gate}/#{m.id}: court file #{p} missing"
      end
    end
  end

  test "every security entry's target resolves to a buildable mutant" do
    for {gate, module, function, arity} <- Catalog.security_gates(),
        m <- entries_for(module, function, arity) do
      assert {:ok, plan} = Mutation.prepare(m), "#{gate}/#{m.id}: target does not resolve"
      assert plan.clauses_mutated >= 1
    end
  end

  test "security entry ids are unique across the catalog" do
    ids = Catalog.ids()
    assert ids == Enum.uniq(ids)
  end
end
