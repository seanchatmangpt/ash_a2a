defmodule AshA2A.ConsequenceKernelTest do
  @moduledoc """
  Kernel runtime through the REAL in-memory `PreparedEffectStore.Memory` (no doubles for the
  store): claims, authority revalidation, class admission and the effector are mediated in
  order, and the durable state is asserted, not the calls.
  """
  use ExUnit.Case, async: true

  alias AshA2A.ConsequenceKernel
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Memory

  defmodule Auth do
    def revalidate("p", _), do: :ok
    def revalidate(_, _), do: {:error, :authority_revoked}
  end

  defmodule Eff do
    def apply(_), do: {:ok, :done}
  end

  defmodule Boom do
    def apply(_), do: {:error, :network}
  end

  defp prepared(over \\ %{}) do
    id = Base.encode16(:crypto.strong_rand_bytes(6))

    Map.merge(
      %{
        prepared_digest: "sha256:" <> id,
        instance: %{request_id: "r-" <> id, effect_id: "e-" <> id},
        consequence_class: :change
      },
      over
    )
  end

  defp opts(store, over \\ []) do
    Keyword.merge(
      [
        store: Memory,
        store_handle: store,
        owner: self(),
        authority: Auth,
        principal: "p",
        effector: Eff
      ],
      over
    )
  end

  setup do
    {:ok, store} = Memory.start_link()
    {:ok, store: store}
  end

  test "mediates claims authority class and effect, ending :completed", %{store: store} do
    p = prepared()
    assert {:ok, :done} = ConsequenceKernel.execute(p, opts(store))
    assert {:ok, %{state: :completed}} = Memory.fetch(store, p.prepared_digest)
  end

  test "an authority refusal stops before the effector; the record stays :claimed", %{
    store: store
  } do
    p = prepared()

    assert {:error, :authority_revoked} =
             ConsequenceKernel.execute(p, opts(store, principal: "q"))

    assert {:ok, %{state: :claimed}} = Memory.fetch(store, p.prepared_digest)
  end

  test "an unclassified consequence is refused before the apply boundary", %{store: store} do
    p = prepared(%{consequence_class: :not_a_class})
    assert {:error, :consequence_unclassified} = ConsequenceKernel.execute(p, opts(store))
    assert {:ok, %{state: :claimed}} = Memory.fetch(store, p.prepared_digest)
  end

  test "an effector error after the apply boundary is unknown_outcome, not failure", %{
    store: store
  } do
    p = prepared()

    assert {:unknown, {:effector_error_after_apply_boundary, :network}} =
             ConsequenceKernel.execute(p, opts(store, effector: Boom))

    assert {:ok, %{state: :unknown_outcome}} = Memory.fetch(store, p.prepared_digest)
  end

  test "the same request claimed by another owner is refused; the same prepared digest cannot be prepared twice",
       %{store: store} do
    p = prepared()
    assert {:ok, :done} = ConsequenceKernel.execute(p, opts(store))
    assert {:error, :prepared_duplicate} = ConsequenceKernel.execute(p, opts(store))

    other = prepared(%{instance: p.instance})

    assert {:error, :claim_conflict} =
             ConsequenceKernel.execute(other, opts(store, owner: :someone_else))
  end
end
