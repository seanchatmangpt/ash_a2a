defmodule AshA2A.C1W3Hardening.ApplyingUnknownTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  test "applying_unknown transition court" do
    v =
      Path.join([File.cwd!(), "priv/sa2a/c1/w3_hardening_vectors/applying_unknown.json"])
      |> File.read!()
      |> Jason.decode!()

    Code.ensure_loaded!(Transition)
    from = String.to_existing_atom(v["from"])
    to = String.to_existing_atom(v["to"])
    assert Transition.admit(from, to) == :ok == v["admit"]
  end
end
