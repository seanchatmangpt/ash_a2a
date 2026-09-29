defmodule AshA2A.ConsequenceKernel.AuthenticatedJournalTest do
  @moduledoc """
  Kernel with the authenticated prepared journal (`:key_provider`) over the REAL in-memory store
  and the REAL HMAC key custody: the sealed record is written before claims, an exception from
  the effector is an unknown outcome (never success, never retried), and the completed outcome
  is recorded in the store. Durable state is asserted, not calls.
  """
  use ExUnit.Case, async: true

  alias AshA2A.ConsequenceKernel
  alias AshA2A.ConsequenceKernel.KeyCustody.HmacSha256
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Memory
  alias AshA2A.ConsequenceKernel.UnknownOutcome

  defmodule Auth do
    def revalidate("p", _), do: :ok
    def revalidate(_, _), do: {:error, :authority_revoked}
  end

  defmodule Eff do
    def apply(_), do: {:ok, :done}
  end

  defmodule Raises do
    def apply(_), do: raise("effector fell over")
  end

  defp prepared do
    {:ok, i} =
      AshA2A.EffectInstance.new(%{
        request: %{"n" => :erlang.unique_integer([:positive])},
        subject: %{"id" => 1},
        effect: %{"op" => "update"}
      })

    {:ok, p} = AshA2A.PreparedEffect.new(i, %{"op" => "update"}, :change)
    p
  end

  defp opts(store, effector) do
    [
      store: Memory,
      store_handle: store,
      owner: self(),
      authority: Auth,
      principal: "p",
      effector: effector,
      key_provider: HmacSha256,
      key_opts: [key: :crypto.strong_rand_bytes(32)]
    ]
  end

  setup do
    {:ok, store} = Memory.start_link()
    {:ok, store: store}
  end

  test "sealed record is journaled and the completed outcome is recorded", %{store: store} do
    p = prepared()
    assert {:ok, :done} = ConsequenceKernel.execute(p, opts(store, Eff))

    assert {:ok, %{state: :completed, outcome: :done, tag: "hmac-sha256:" <> _}} =
             Memory.fetch(store, p.prepared_digest)
  end

  test "an effector exception is an unknown outcome, journaled as such", %{store: store} do
    p = prepared()

    assert {:unknown, %UnknownOutcome{reason: {:effector_exception, %RuntimeError{}}}} =
             ConsequenceKernel.execute(p, opts(store, Raises))

    assert {:ok, %{state: :unknown_outcome}} = Memory.fetch(store, p.prepared_digest)
  end

  test "a missing key is refused before any claim or effect", %{store: store} do
    p = prepared()
    bad = Keyword.put(opts(store, Eff), :key_opts, [])
    assert {:error, :prepared_key_unavailable} = ConsequenceKernel.execute(p, bad)
    assert :not_found = Memory.fetch(store, p.prepared_digest)
  end
end
