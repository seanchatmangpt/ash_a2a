# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1W4.ObserveNotConsequenceTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.W4.Route

  test "observe_not_consequence" do
    v = "priv/sa2a/c1/w4_vectors/observe_not_consequence.json" |> File.read!() |> Jason.decode!()

    input =
      case v["input"] do
        "change" -> :change
        "external_do" -> :external_do
        "observe" -> :observe
        "unknown" -> :unknown
        "nil" -> nil
        _ -> :other
      end

    assert Atom.to_string(Route.classify(input)) == v["route"]
  end
end
