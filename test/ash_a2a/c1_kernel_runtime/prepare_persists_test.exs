defmodule AshA2A.C1KernelRuntime.PreparePersistsTest do
  @moduledoc """
  `prepare_persists` is a same-state step (prepared -> prepared): persisting the prepared record
  is not a state transition, so `Transition.admit/2` (which refuses self-loops, as
  `duplicate_prepare` requires) cannot be its oracle. It is asserted through the real store:
  the record persists in the vector's state, and a second put of the same digest is refused.
  """
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Memory
  alias AshA2A.ConsequenceKernel.Runtime.{PrepareStage, StoreHandle}

  @vector Path.expand(
            "../../../priv/sa2a/c1/kernel_runtime_vectors/prepare_persists.json",
            __DIR__
          )
  test "prepare_persists portable transition contract" do
    v = @vector |> File.read!() |> Jason.decode!()
    assert v["schema"] == "sa2a.c1.kernel-runtime.v1"
    assert v["decision"] == "admit" and v["from"] == v["to"]

    {:ok, store} = Memory.start_link()
    handle = StoreHandle.new(Memory, store)
    p = %{digest: "sha256:prep", instance: %{request_id: "r", effect_id: "e"}}

    assert :ok = PrepareStage.run(handle, p)
    assert {:ok, %{state: state, prepared: ^p}} = Memory.fetch(store, p.digest)
    assert Atom.to_string(state) == v["from"]
    assert {:error, :prepared_duplicate} = PrepareStage.run(handle, p)
  end
end
