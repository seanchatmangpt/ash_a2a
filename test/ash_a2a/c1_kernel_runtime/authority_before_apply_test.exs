defmodule AshA2A.C1KernelRuntime.AuthorityBeforeApplyTest do
  @moduledoc """
  `authority_before_apply` is a same-state step (claimed -> claimed): authority revalidation
  happens while the record is claimed and changes nothing, so `Transition.admit/2` (which
  refuses self-loops, as the refusal vectors require) is not its oracle. It is asserted
  through the real store and stages: the record is `claimed` before and after a successful
  revalidation, and only then may it move to `applying`.
  """
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Memory

  alias AshA2A.ConsequenceKernel.Runtime.{
    ApplyingStage,
    AuthorityStage,
    ClaimStage,
    PrepareStage,
    StoreHandle
  }

  defmodule Auth do
    def revalidate("p", _), do: :ok
    def revalidate(_, _), do: {:error, :authority_revoked}
  end

  @vector Path.expand(
            "../../../priv/sa2a/c1/kernel_runtime_vectors/authority_before_apply.json",
            __DIR__
          )
  test "authority_before_apply portable transition contract" do
    v = @vector |> File.read!() |> Jason.decode!()
    assert v["schema"] == "sa2a.c1.kernel-runtime.v1"
    assert v["decision"] == "admit" and v["from"] == v["to"]

    {:ok, store} = Memory.start_link()
    handle = StoreHandle.new(Memory, store)
    p = %{prepared_digest: "sha256:auth", instance: %{request_id: "r", effect_id: "e"}}
    :ok = PrepareStage.run(handle, p)
    :ok = ClaimStage.run(handle, p, self())

    assert {:ok, %{state: state}} = Memory.fetch(store, p.prepared_digest)
    assert Atom.to_string(state) == v["from"]
    assert :ok = AuthorityStage.run(Auth, "p", p)
    assert {:ok, %{state: ^state}} = Memory.fetch(store, p.prepared_digest)
    assert {:error, :authority_revoked} = AuthorityStage.run(Auth, "q", p)
    assert {:ok, %{state: ^state}} = Memory.fetch(store, p.prepared_digest)
    assert :ok = ApplyingStage.run(handle, p)
  end
end
