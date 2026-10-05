# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernelTest do
  @moduledoc """
  Kernel runtime through the REAL in-memory `PreparedEffectStore.Memory` (no doubles for the
  store): claims, authority revalidation, class admission and the effector are mediated in
  order, and the durable state is asserted, not the calls.
  """
  use ExUnit.Case, async: true

  alias AshA2A.ConsequenceKernel
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Memory
  alias AshA2A.ConsequenceKernel.W5.EffectClaimStore.Memory, as: ClaimMemory

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
        instance: %{
          request_id: "r-" <> id,
          effect_id: "e-" <> id,
          subject_digest: "sha256:subject-" <> id
        },
        consequence_class: :change
      },
      over
    )
  end

  defp opts({store, claims}, over \\ []) do
    Keyword.merge(
      [
        store: Memory,
        store_handle: store,
        owner: self(),
        authority: Auth,
        principal: "p",
        effector: Eff,
        claim_store: ClaimMemory,
        claim_store_handle: claims,
        claim_key: String.duplicate("k", 32)
      ],
      over
    )
  end

  setup do
    {:ok, store} = Memory.start_link()
    {:ok, claims} = ClaimMemory.start_link()
    {:ok, store: store, claims: claims}
  end

  test "mediates claims authority class and effect, ending :completed", %{
    store: store,
    claims: claims
  } do
    p = prepared()
    assert {:ok, :done} = ConsequenceKernel.execute(p, opts({store, claims}))
    assert {:ok, %{state: :completed}} = Memory.fetch(store, p.prepared_digest)

    assert {:ok, %{state: :completed, claim_id: claim_id}} =
             ClaimMemory.fetch_effect(claims, p.instance.effect_id)

    assert {:ok, receipts} = ClaimMemory.receipts(claims, claim_id)
    assert Enum.map(receipts, & &1["event"]) == ["claimed", "doing", "completed"]
    assert :ok = AshA2A.ConsequenceKernel.W5.ClaimReceipt.verify_chain(receipts)
  end

  test "an authority refusal stops before the effector; the record stays :claimed", %{
    store: store,
    claims: claims
  } do
    p = prepared()

    assert {:error, :authority_revoked} =
             ConsequenceKernel.execute(p, opts({store, claims}, principal: "q"))

    assert {:ok, %{state: :claimed}} = Memory.fetch(store, p.prepared_digest)
  end

  test "an unclassified consequence is refused before the apply boundary", %{
    store: store,
    claims: claims
  } do
    p = prepared(%{consequence_class: :not_a_class})

    assert {:error, :consequence_unclassified} =
             ConsequenceKernel.execute(p, opts({store, claims}))

    assert {:ok, %{state: :claimed}} = Memory.fetch(store, p.prepared_digest)
  end

  test "an effector error after the apply boundary is unknown_outcome, not failure", %{
    store: store,
    claims: claims
  } do
    p = prepared()

    assert {:unknown, {:effector_error_after_apply_boundary, :network}} =
             ConsequenceKernel.execute(p, opts({store, claims}, effector: Boom))

    assert {:ok, %{state: :unknown_outcome}} = Memory.fetch(store, p.prepared_digest)

    assert {:ok, %{state: :unknown_outcome}} =
             ClaimMemory.fetch_effect(claims, p.instance.effect_id)
  end

  test "without an independent claim store the run is refused before the apply boundary", %{
    store: store,
    claims: claims
  } do
    p = prepared()
    bare = Keyword.drop(opts({store, claims}), [:claim_store, :claim_store_handle, :claim_key])

    assert {:error, :independent_effect_claim_store_required} = ConsequenceKernel.execute(p, bare)
    assert {:ok, %{state: :claimed}} = Memory.fetch(store, p.prepared_digest)
  end

  test "the same request claimed by another owner is refused; the same prepared digest cannot be prepared twice",
       %{store: store, claims: claims} do
    p = prepared()
    assert {:ok, :done} = ConsequenceKernel.execute(p, opts({store, claims}))
    assert {:error, :prepared_duplicate} = ConsequenceKernel.execute(p, opts({store, claims}))

    other = prepared(%{instance: p.instance})

    assert {:error, :claim_conflict} =
             ConsequenceKernel.execute(other, opts({store, claims}, owner: :someone_else))
  end
end
