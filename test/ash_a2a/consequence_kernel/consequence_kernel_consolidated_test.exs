# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT

# ==============================================================================
# Consolidated Test Suite: Consequence Kernel
# Contains original tests:
#   - test/ash_a2a/consequence_kernel/authenticated_journal_test.exs
#   - test/ash_a2a/consequence_kernel/authority_revalidation_test.exs
#   - test/ash_a2a/consequence_kernel/call_graph_court_test.exs
#   - test/ash_a2a/consequence_kernel/claim_test.exs
#   - test/ash_a2a/consequence_kernel/complete_mediation_test.exs
#   - test/ash_a2a/consequence_kernel/consequence_kernel_test.exs
#   - test/ash_a2a/consequence_kernel/effect_identity_test.exs
#   - test/ash_a2a/consequence_kernel/exact_subject_test.exs
#   - test/ash_a2a/consequence_kernel/ocel_test.exs
#   - test/ash_a2a/consequence_kernel/receipt_chain_test.exs
#   - test/ash_a2a/consequence_kernel/receipt_test.exs
#   - test/ash_a2a/consequence_kernel/refusal_registry_test.exs
#   - test/ash_a2a/consequence_kernel/replay_evidence_test.exs
#   - test/ash_a2a/consequence_kernel/request_identity_test.exs
#   - test/ash_a2a/consequence_kernel/standing_test.exs
#   - test/ash_a2a/consequence_kernel/unknown_outcome_test.exs
#   - test/ash_a2a/consequence_kernel/wire_test.exs
# ==============================================================================

# ------------------------------------------------------------------------------
# SECTION 1: Original test/ash_a2a/consequence_kernel/authenticated_journal_test.exs
# ------------------------------------------------------------------------------

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

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
  alias AshA2A.ConsequenceKernel.EffectClaimStore.Memory, as: ClaimMemory

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

  defp opts({store, claims}, effector) do
    [
      store: Memory,
      store_handle: store,
      owner: self(),
      authority: Auth,
      principal: "p",
      effector: effector,
      claim_store: ClaimMemory,
      claim_store_handle: claims,
      claim_key: String.duplicate("k", 32),
      key_provider: HmacSha256,
      key_opts: [key: :crypto.strong_rand_bytes(32)]
    ]
  end

  setup do
    {:ok, store} = Memory.start_link()
    {:ok, claims} = ClaimMemory.start_link()
    {:ok, store: store, claims: claims}
  end

  test "sealed record is journaled and the completed outcome is recorded", %{
    store: store,
    claims: claims
  } do
    p = prepared()
    assert {:ok, :done} = ConsequenceKernel.execute(p, opts({store, claims}, Eff))

    assert {:ok, %{state: :completed, outcome: :done, tag: "hmac-sha256:" <> _}} =
             Memory.fetch(store, p.prepared_digest)
  end

  test "an effector exception is an unknown outcome, journaled as such", %{
    store: store,
    claims: claims
  } do
    p = prepared()

    assert {:unknown, %UnknownOutcome{reason: {:effector_exception, %RuntimeError{}}}} =
             ConsequenceKernel.execute(p, opts({store, claims}, Raises))

    assert {:ok, %{state: :unknown_outcome}} = Memory.fetch(store, p.prepared_digest)
  end

  test "a missing key is refused before any claim or effect", %{store: store, claims: claims} do
    p = prepared()
    bad = Keyword.put(opts({store, claims}, Eff), :key_opts, [])
    assert {:error, :prepared_key_unavailable} = ConsequenceKernel.execute(p, bad)
    assert :not_found = Memory.fetch(store, p.prepared_digest)
  end
end

# ------------------------------------------------------------------------------
# SECTION 2: Original test/ash_a2a/consequence_kernel/authority_revalidation_test.exs
# ------------------------------------------------------------------------------

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.AuthorityRevalidationTest do
  use ExUnit.Case, async: true

  defmodule Broker do
    def revalidate(p, s, c, e), do: {:ok, {p, s, c, e}}
  end

  test "uses live broker" do
    p = %{instance: %{subject_digest: "s"}, consequence_class: :change, authority_epoch: 2}

    assert {:ok, {"p", "s", :change, 2}} =
             AshA2A.ConsequenceKernel.AuthorityRevalidation.check(Broker, p, "p")
  end
end

# ------------------------------------------------------------------------------
# SECTION 3: Original test/ash_a2a/consequence_kernel/call_graph_court_test.exs
# ------------------------------------------------------------------------------

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.CallGraphCourtTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.{CallGraphCourt, CompleteMediation}
  @vectors Path.expand("../../../priv/sa2a/c1/call_graph_vectors/*.json", __DIR__)
  test "portable call-graph vectors preserve complete mediation" do
    files = Path.wildcard(@vectors)
    assert length(files) == 50

    Enum.each(files, fn file ->
      vector = file |> File.read!() |> Jason.decode!()
      edge = Map.fetch!(vector, "edge")
      {decision, reason} = CallGraphCourt.classify(edge)
      assert Atom.to_string(decision) == vector["expected"]["decision"], file
      assert Atom.to_string(reason) == vector["expected"]["reason"], file

      case decision do
        :admit -> assert {:ok, ^reason} = CompleteMediation.admit_call_edge(edge)
        :refuse -> assert {:error, ^reason} = CompleteMediation.admit_call_edge(edge)
      end
    end)
  end
end

# ------------------------------------------------------------------------------
# SECTION 4: Original test/ash_a2a/consequence_kernel/claim_test.exs
# ------------------------------------------------------------------------------

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ClaimTest do
  use ExUnit.Case, async: true

  defmodule Store do
    def claim_request(r, o), do: {:request, r, o}
    def claim_effect(e, o), do: {:effect, e, o}
    def release_effect(e, o), do: {:release, e, o}
  end

  test "request and effect claims are independent" do
    assert {:request, "r", "o"} = AshA2A.ConsequenceKernel.Claim.request(Store, "r", "o")
    assert {:effect, "e", "o"} = AshA2A.ConsequenceKernel.Claim.effect(Store, "e", "o")
  end
end

# ------------------------------------------------------------------------------
# SECTION 5: Original test/ash_a2a/consequence_kernel/complete_mediation_test.exs
# ------------------------------------------------------------------------------

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.CompleteMediationTest do
  use ExUnit.Case, async: true

  test "direct dispatcher is a kernel bypass" do
    assert {:error, :kernel_bypass} =
             AshA2A.ConsequenceKernel.CompleteMediation.admit_call_path([AshA2A.Dispatcher])
  end
end

# ------------------------------------------------------------------------------
# SECTION 6: Original test/ash_a2a/consequence_kernel/consequence_kernel_test.exs
# ------------------------------------------------------------------------------

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
  alias AshA2A.ConsequenceKernel.EffectClaimStore.Memory, as: ClaimMemory

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
    assert :ok = AshA2A.ConsequenceKernel.Claims.Receipt.verify_chain(receipts)
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

# ------------------------------------------------------------------------------
# SECTION 7: Original test/ash_a2a/consequence_kernel/effect_identity_test.exs
# ------------------------------------------------------------------------------

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.EffectIdentityTest do
  use ExUnit.Case, async: true

  test "effect identity binds request" do
    assert AshA2A.ConsequenceKernel.EffectIdentity.derive("r1", %{"x" => 1}) !=
             AshA2A.ConsequenceKernel.EffectIdentity.derive("r2", %{"x" => 1})
  end
end

# ------------------------------------------------------------------------------
# SECTION 8: Original test/ash_a2a/consequence_kernel/exact_subject_test.exs
# ------------------------------------------------------------------------------

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ExactSubjectTest do
  use ExUnit.Case, async: true

  test "refuses drift" do
    assert :ok = AshA2A.ConsequenceKernel.ExactSubject.bind("a", "a")

    assert {:error, :prepared_record_identity_mismatch} =
             AshA2A.ConsequenceKernel.ExactSubject.bind("a", "b")
  end
end

# ------------------------------------------------------------------------------
# SECTION 9: Original test/ash_a2a/consequence_kernel/ocel_test.exs
# ------------------------------------------------------------------------------

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.OcelProjectionTest do
  use ExUnit.Case, async: true

  test "projection preserves exact identity" do
    p = %{instance: %{effect_id: "e", subject_digest: "s"}, prepared_digest: "p"}
    x = AshA2A.ConsequenceKernel.Ocel.project(p, :ok)
    assert x["effect_id"] == "e"
    assert x["subject_digest"] == "s"
  end
end

# ------------------------------------------------------------------------------
# SECTION 10: Original test/ash_a2a/consequence_kernel/receipt_chain_test.exs
# ------------------------------------------------------------------------------

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ReceiptChainTest do
  use ExUnit.Case, async: true

  test "chain digest binds predecessor" do
    assert AshA2A.ConsequenceKernel.ReceiptChain.next("a", %{"x" => 1}) !=
             AshA2A.ConsequenceKernel.ReceiptChain.next("b", %{"x" => 1})
  end
end

# ------------------------------------------------------------------------------
# SECTION 11: Original test/ash_a2a/consequence_kernel/receipt_test.exs
# ------------------------------------------------------------------------------

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.KernelReceiptTest do
  use ExUnit.Case, async: true

  test "receipt binds prepared identity" do
    p = %{
      instance: %{effect_id: "e", subject_digest: "s"},
      prepared_digest: "p",
      authority_epoch: 1
    }

    assert {:ok, r} = AshA2A.ConsequenceKernel.Receipt.issue(p, :ok)
    assert r.effect_id == "e"
    assert r.receipt_digest =~ "sha256:"
  end
end

# ------------------------------------------------------------------------------
# SECTION 12: Original test/ash_a2a/consequence_kernel/refusal_registry_test.exs
# ------------------------------------------------------------------------------

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.RefusalRegistryTest do
  use ExUnit.Case, async: true

  test "kernel refusals are typed" do
    for c <- AshA2A.ConsequenceKernel.RefusalRegistry.codes(),
        do: assert(AshA2A.ConsequenceKernel.RefusalRegistry.known?(c))
  end
end

# ------------------------------------------------------------------------------
# SECTION 13: Original test/ash_a2a/consequence_kernel/replay_evidence_test.exs
# ------------------------------------------------------------------------------

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ReplayEvidenceTest do
  use ExUnit.Case, async: true

  test "refuses effect divergence" do
    p = %{instance: %{effect_id: "a"}, prepared_digest: "p"}
    r = %{effect_id: "b", prepared_digest: "p"}

    assert {:error, :replay_effect_divergence} =
             AshA2A.ConsequenceKernel.ReplayEvidence.verify(p, r)
  end
end

# ------------------------------------------------------------------------------
# SECTION 14: Original test/ash_a2a/consequence_kernel/request_identity_test.exs
# ------------------------------------------------------------------------------

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.RequestIdentityTest do
  use ExUnit.Case, async: true

  test "request identity is deterministic" do
    assert AshA2A.ConsequenceKernel.RequestIdentity.derive(%{"a" => 1}) ==
             AshA2A.ConsequenceKernel.RequestIdentity.derive(%{"a" => 1})
  end
end

# ------------------------------------------------------------------------------
# SECTION 15: Original test/ash_a2a/consequence_kernel/standing_test.exs
# ------------------------------------------------------------------------------

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.StandingTest do
  use ExUnit.Case, async: true

  test "unknown outcome has no standing" do
    assert {:error, :standing_unknown_outcome} =
             AshA2A.ConsequenceKernel.Standing.derive(%{outcome: :unknown})
  end
end

# ------------------------------------------------------------------------------
# SECTION 16: Original test/ash_a2a/consequence_kernel/unknown_outcome_test.exs
# ------------------------------------------------------------------------------

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.UnknownOutcomeTest do
  use ExUnit.Case, async: true

  test "unknown retains effect identity" do
    p = %{instance: %{effect_id: "e"}, prepared_digest: "p"}
    x = AshA2A.ConsequenceKernel.UnknownOutcome.new(p, :ambiguous)
    assert x.effect_id == "e"
  end
end

# ------------------------------------------------------------------------------
# SECTION 17: Original test/ash_a2a/consequence_kernel/wire_test.exs
# ------------------------------------------------------------------------------

# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.WireTest do
  use ExUnit.Case, async: true

  test "wire digest uses canonical identity" do
    assert AshA2A.ConsequenceKernel.Wire.digest(%{"b" => 2, "a" => 1}) ==
             AshA2A.ConsequenceKernel.Wire.digest(%{"a" => 1, "b" => 2})
  end
end

