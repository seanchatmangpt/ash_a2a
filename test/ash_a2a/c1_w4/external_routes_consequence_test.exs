defmodule AshA2A.C1W4.ExternalRoutesConsequenceTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.W4.Route

  test "external_routes_consequence" do
    v =
      "priv/sa2a/c1/w4_vectors/external_routes_consequence.json"
      |> File.read!()
      |> Jason.decode!()

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
