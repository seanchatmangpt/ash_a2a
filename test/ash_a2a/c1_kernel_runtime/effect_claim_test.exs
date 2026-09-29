defmodule AshA2A.C1KernelRuntime.EffectClaimTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  setup_all do
    # Transition owns the state atoms the vectors name; load it before String.to_existing_atom.
    Code.ensure_loaded!(Transition)
    :ok
  end

  @vector Path.expand("../../../priv/sa2a/c1/kernel_runtime_vectors/effect_claim.json", __DIR__)
  test "effect_claim portable transition contract" do
    v = @vector |> File.read!() |> Jason.decode!()

    result =
      Transition.admit(String.to_existing_atom(v["from"]), String.to_existing_atom(v["to"]))

    assert if v["decision"] == "admit", do: result == :ok, else: match?({:error, _}, result)
    assert v["schema"] == "sa2a.c1.kernel-runtime.v1"
  end
end
