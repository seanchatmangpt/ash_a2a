# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT

# ==============================================================================
# Consolidated Test Suite: C1 Vectors
# Contains original tests:
#   - test/ash_a2a/c1_vectors/canonical_object_test.exs
#   - test/ash_a2a/c1_vectors/consequence_classes_test.exs
#   - test/ash_a2a/c1_vectors/dispatcher_bypass_test.exs
#   - test/ash_a2a/c1_vectors/effect_claim_independence_test.exs
#   - test/ash_a2a/c1_vectors/ocel_unknown_test.exs
#   - test/ash_a2a/c1_vectors/portable_wire_test.exs
#   - test/ash_a2a/c1_vectors/receipt_predecessor_test.exs
#   - test/ash_a2a/c1_vectors/refusal_totality_test.exs
#   - test/ash_a2a/c1_vectors/request_effect_separation_test.exs
#   - test/ash_a2a/c1_vectors/unknown_standing_test.exs
# ==============================================================================

# --- SECTION 1: Original test/ash_a2a/c1_vectors/canonical_object_test.exs ---
defmodule AshA2A.C1CanonicalObjectVectorTest do
  use ExUnit.Case, async: true

  test "map order converges" do
    assert AshA2A.Identity.Canonical.digest(%{"a" => 1, "b" => 2}) ==
             AshA2A.Identity.Canonical.digest(%{"b" => 2, "a" => 1})
  end
end

# --- SECTION 2: Original test/ash_a2a/c1_vectors/consequence_classes_test.exs ---
defmodule AshA2A.C1ConsequenceClassesTest do
  use ExUnit.Case, async: true

  test "known classes admitted unknown refused" do
    for x <- [:observe, :change, :external], do: assert(AshA2A.ConsequenceClass.admitted?(x))
    refute AshA2A.ConsequenceClass.admitted?(:unknown)
  end
end

# --- SECTION 3: Original test/ash_a2a/c1_vectors/dispatcher_bypass_test.exs ---
defmodule AshA2A.C1DispatcherBypassTest do
  use ExUnit.Case, async: true

  test "legacy direct dispatch refused" do
    assert {:error, :kernel_bypass} =
             AshA2A.ConsequenceKernel.CompleteMediation.admit_call_path([AshA2A.Dispatcher])
  end
end

# --- SECTION 4: Original test/ash_a2a/c1_vectors/effect_claim_independence_test.exs ---
defmodule AshA2A.C1EffectClaimIndependenceTest do
  use ExUnit.Case, async: true

  test "claim API has separate request and effect operations" do
    assert Code.ensure_loaded?(AshA2A.ConsequenceKernel.Claim)
    assert function_exported?(AshA2A.ConsequenceKernel.Claim, :request, 3)
    assert function_exported?(AshA2A.ConsequenceKernel.Claim, :effect, 3)
  end
end

# --- SECTION 5: Original test/ash_a2a/c1_vectors/ocel_unknown_test.exs ---
defmodule AshA2A.C1OcelUnknownTest do
  use ExUnit.Case, async: true

  test "unknown remains explicit evidence" do
    p = %{instance: %{effect_id: "e", subject_digest: "s"}, prepared_digest: "p"}
    assert AshA2A.ConsequenceKernel.Ocel.project(p, :unknown)["outcome"] == "unknown"
  end
end

# --- SECTION 6: Original test/ash_a2a/c1_vectors/portable_wire_test.exs ---
defmodule AshA2A.C1PortableWireTest do
  use ExUnit.Case, async: true

  test "wire identity is sha256 JCS domain" do
    assert {:ok, d} = AshA2A.ConsequenceKernel.Wire.digest(%{"x" => 1})
    assert byte_size(d) == 71
  end
end

# --- SECTION 7: Original test/ash_a2a/c1_vectors/receipt_predecessor_test.exs ---
defmodule AshA2A.C1ReceiptPredecessorTest do
  use ExUnit.Case, async: true

  test "predecessor changes digest" do
    assert AshA2A.ConsequenceKernel.ReceiptChain.next("a", %{"r" => 1}) !=
             AshA2A.ConsequenceKernel.ReceiptChain.next("b", %{"r" => 1})
  end
end

# --- SECTION 8: Original test/ash_a2a/c1_vectors/refusal_totality_test.exs ---
defmodule AshA2A.C1RefusalTotalityTest do
  use ExUnit.Case, async: true

  alias AshA2A.ConsequenceKernel.RefusalRegistry
  alias AshA2A.Semantic.Refusal

  test "registry is nonempty and unique" do
    codes = RefusalRegistry.codes()
    assert length(codes) > 0
    assert Enum.uniq(codes) == codes
  end

  test "every consequence-kernel refusal code has an explicit S42 class" do
    mapping = Refusal.mapping()

    for code <- RefusalRegistry.codes() do
      assert Map.has_key?(mapping, code), "#{code} has no S42 class"
    end
  end
end

# --- SECTION 9: Original test/ash_a2a/c1_vectors/request_effect_separation_test.exs ---
defmodule AshA2A.C1RequestEffectSeparationTest do
  use ExUnit.Case, async: true

  test "request and effect domains differ" do
    assert AshA2A.ConsequenceKernel.RequestIdentity.derive(%{"x" => 1}) !=
             AshA2A.ConsequenceKernel.EffectIdentity.derive("r", %{"x" => 1})
  end
end

# --- SECTION 10: Original test/ash_a2a/c1_vectors/unknown_standing_test.exs ---
defmodule AshA2A.C1UnknownStandingTest do
  use ExUnit.Case, async: true

  test "unknown cannot derive standing" do
    assert {:error, _} = AshA2A.ConsequenceKernel.Standing.derive(%{outcome: :unknown})
  end
end

