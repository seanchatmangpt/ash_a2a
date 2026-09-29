defmodule AshA2A.C1W3Hardening.UnknownReleasedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.Runtime.Transition
  test "unknown_released transition court" do
    v = Path.join([File.cwd!(), "priv/sa2a/c1/w3_hardening_vectors/unknown_released.json"]) |> File.read!() |> Jason.decode!()
    assert Transition.valid?(String.to_existing_atom(v["from"]), String.to_existing_atom(v["to"])) == v["admit"]
  end
end
