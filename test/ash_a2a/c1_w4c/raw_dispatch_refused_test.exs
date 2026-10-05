# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1W4C.RawDispatchRefusedTest do
  use ExUnit.Case, async: true

  alias AshA2A.ConsequenceKernel.W4C.{
    AdmittedTopology,
    ChicagoAdapter,
    ClosurePredicate,
    ClosureReceipt,
    GraphEdge,
    GraphReport,
    UnresolvedApply
  }

  test "raw_dispatch_refused" do
    assert {:error, _} =
             ClosurePredicate.evaluate([
               %GraphEdge{
                 caller: "Elixir.Legacy",
                 callee: "Elixir.AshA2A.Dispatcher",
                 kind: :dispatcher
               }
             ])
  end
end
