defmodule AshA2A.C1KernelRuntime.AuthorityBeforeApplyTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition
  @vector Path.expand("../../../priv/sa2a/c1/kernel_runtime_vectors/authority_before_apply.json", __DIR__)
  test "authority_before_apply portable transition contract" do
    v=@vector |> File.read!() |> Jason.decode!()
    result=Transition.admit(String.to_existing_atom(v["from"]),String.to_existing_atom(v["to"]))
    assert (if v["decision"]=="admit", do: result==:ok, else: match?({:error,_},result))
    assert v["schema"]=="sa2a.c1.kernel-runtime.v1"
  end
end
