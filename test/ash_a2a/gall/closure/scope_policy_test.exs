# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.ScopePolicyTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.{Determinism, ScopePolicy}

  test "scope binds exact command input and target" do
    command = %{input: %{label: "x"}, target: "Item"}
    scope = %{input_digest: Determinism.digest(command.input), target: "Item"}
    assert {:ok, ^scope} = ScopePolicy.admit(scope, command)

    assert {:error, {:refused_gall, :scope_policy, :input_digest_mismatch}} =
             ScopePolicy.admit(Map.put(scope, :input_digest, "wrong"), command)
  end
end
