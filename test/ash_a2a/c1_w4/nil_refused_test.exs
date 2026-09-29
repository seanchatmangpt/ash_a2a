defmodule AshA2A.C1W4.NilRefusedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.W4.Route

  test "nil_refused" do
    v = "priv/sa2a/c1/w4_vectors/nil_refused.json" |> File.read!() |> Jason.decode!()

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
