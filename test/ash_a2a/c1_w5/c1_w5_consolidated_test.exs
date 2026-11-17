# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT

# ==============================================================================
# Consolidated Test Suite: C1 W5 Totality Suite
# Target: test/ash_a2a/c1_w5/c1_w5_consolidated_test.exs
# Contains original tests:
#   - test/ash_a2a/c1_w5/after_do_before_receipt_test.exs
#   - test/ash_a2a/c1_w5/after_receipt_test.exs
#   - test/ash_a2a/c1_w5/before_do_test.exs
#   - test/ash_a2a/c1_w5/claim_identity_invalid_test.exs
#   - test/ash_a2a/c1_w5/claim_identity_test.exs
#   - test/ash_a2a/c1_w5/independent_claim_test.exs
#   - test/ash_a2a/c1_w5/prepared_match_test.exs
#   - test/ash_a2a/c1_w5/prepared_mismatch_test.exs
#   - test/ash_a2a/c1_w5/receipt_chain_test.exs
#   - test/ash_a2a/c1_w5/reconcile_applied_test.exs
#   - test/ash_a2a/c1_w5/reconcile_not_applied_test.exs
#   - test/ash_a2a/c1_w5/reconcile_uncertain_test.exs
#   - test/ash_a2a/c1_w5/replay_exact_effect_test.exs
#   - test/ash_a2a/c1_w5/replay_exact_prepared_test.exs
#   - test/ash_a2a/c1_w5/same_claim_refused_test.exs
#   - test/ash_a2a/c1_w5/standing_complete_test.exs
#   - test/ash_a2a/c1_w5/standing_refused_test.exs
#   - test/ash_a2a/c1_w5/standing_unknown_test.exs
#   - test/ash_a2a/c1_w5/unknown_no_retry_test.exs
#   - test/ash_a2a/c1_w5/unknown_reconcile_test.exs
# ==============================================================================

# --- SECTION 1: Original test/ash_a2a/c1_w5/after_do_before_receipt_test.exs ---
defmodule AshA2A.C1W5.AfterDoBeforeReceiptTest do
  use ExUnit.Case, async: true

  test "after_do_before_receipt" do
    p =
      Path.join([File.cwd!(), "priv", "sa2a", "c1", "w5_vectors", "after_do_before_receipt.json"])

    assert File.read!(p) =~ "\"sa2a-c1-w5-v1\""
  end
end

# --- SECTION 2: Original test/ash_a2a/c1_w5/after_receipt_test.exs ---
defmodule AshA2A.C1W5.AfterReceiptTest do
  use ExUnit.Case, async: true

  test "after_receipt" do
    p = Path.join([File.cwd!(), "priv", "sa2a", "c1", "w5_vectors", "after_receipt.json"])
    assert File.read!(p) =~ "\"sa2a-c1-w5-v1\""
  end
end

# --- SECTION 3: Original test/ash_a2a/c1_w5/before_do_test.exs ---
defmodule AshA2A.C1W5.BeforeDoTest do
  use ExUnit.Case, async: true

  test "before_do" do
    p = Path.join([File.cwd!(), "priv", "sa2a", "c1", "w5_vectors", "before_do.json"])
    assert File.read!(p) =~ "\"sa2a-c1-w5-v1\""
  end
end

# --- SECTION 4: Original test/ash_a2a/c1_w5/claim_identity_invalid_test.exs ---
defmodule AshA2A.C1W5.ClaimIdentityInvalidTest do
  use ExUnit.Case, async: true

  test "claim_identity_invalid" do
    p =
      Path.join([File.cwd!(), "priv", "sa2a", "c1", "w5_vectors", "claim_identity_invalid.json"])

    assert File.read!(p) =~ "\"sa2a-c1-w5-v1\""
  end
end

# --- SECTION 5: Original test/ash_a2a/c1_w5/claim_identity_test.exs ---
defmodule AshA2A.C1W5.ClaimIdentityTest do
  use ExUnit.Case, async: true

  test "claim_identity" do
    p = Path.join([File.cwd!(), "priv", "sa2a", "c1", "w5_vectors", "claim_identity.json"])
    assert File.read!(p) =~ "\"sa2a-c1-w5-v1\""
  end
end

# --- SECTION 6: Original test/ash_a2a/c1_w5/independent_claim_test.exs ---
defmodule AshA2A.C1W5.IndependentClaimTest do
  use ExUnit.Case, async: true

  test "independent_claim" do
    p = Path.join([File.cwd!(), "priv", "sa2a", "c1", "w5_vectors", "independent_claim.json"])
    assert File.read!(p) =~ "\"sa2a-c1-w5-v1\""
  end
end

# --- SECTION 7: Original test/ash_a2a/c1_w5/prepared_match_test.exs ---
defmodule AshA2A.C1W5.PreparedMatchTest do
  use ExUnit.Case, async: true

  test "prepared_match" do
    p = Path.join([File.cwd!(), "priv", "sa2a", "c1", "w5_vectors", "prepared_match.json"])
    assert File.read!(p) =~ "\"sa2a-c1-w5-v1\""
  end
end

# --- SECTION 8: Original test/ash_a2a/c1_w5/prepared_mismatch_test.exs ---
defmodule AshA2A.C1W5.PreparedMismatchTest do
  use ExUnit.Case, async: true

  test "prepared_mismatch" do
    p = Path.join([File.cwd!(), "priv", "sa2a", "c1", "w5_vectors", "prepared_mismatch.json"])
    assert File.read!(p) =~ "\"sa2a-c1-w5-v1\""
  end
end

# --- SECTION 9: Original test/ash_a2a/c1_w5/receipt_chain_test.exs ---
defmodule AshA2A.C1W5.ReceiptChainTest do
  use ExUnit.Case, async: true

  test "receipt_chain" do
    p = Path.join([File.cwd!(), "priv", "sa2a", "c1", "w5_vectors", "receipt_chain.json"])
    assert File.read!(p) =~ "\"sa2a-c1-w5-v1\""
  end
end

# --- SECTION 10: Original test/ash_a2a/c1_w5/reconcile_applied_test.exs ---
defmodule AshA2A.C1W5.ReconcileAppliedTest do
  use ExUnit.Case, async: true

  test "reconcile_applied" do
    p = Path.join([File.cwd!(), "priv", "sa2a", "c1", "w5_vectors", "reconcile_applied.json"])
    assert File.read!(p) =~ "\"sa2a-c1-w5-v1\""
  end
end

# --- SECTION 11: Original test/ash_a2a/c1_w5/reconcile_not_applied_test.exs ---
defmodule AshA2A.C1W5.ReconcileNotAppliedTest do
  use ExUnit.Case, async: true

  test "reconcile_not_applied" do
    p = Path.join([File.cwd!(), "priv", "sa2a", "c1", "w5_vectors", "reconcile_not_applied.json"])
    assert File.read!(p) =~ "\"sa2a-c1-w5-v1\""
  end
end

# --- SECTION 12: Original test/ash_a2a/c1_w5/reconcile_uncertain_test.exs ---
defmodule AshA2A.C1W5.ReconcileUncertainTest do
  use ExUnit.Case, async: true

  test "reconcile_uncertain" do
    p = Path.join([File.cwd!(), "priv", "sa2a", "c1", "w5_vectors", "reconcile_uncertain.json"])
    assert File.read!(p) =~ "\"sa2a-c1-w5-v1\""
  end
end

# --- SECTION 13: Original test/ash_a2a/c1_w5/replay_exact_effect_test.exs ---
defmodule AshA2A.C1W5.ReplayExactEffectTest do
  use ExUnit.Case, async: true

  test "replay_exact_effect" do
    p = Path.join([File.cwd!(), "priv", "sa2a", "c1", "w5_vectors", "replay_exact_effect.json"])
    assert File.read!(p) =~ "\"sa2a-c1-w5-v1\""
  end
end

# --- SECTION 14: Original test/ash_a2a/c1_w5/replay_exact_prepared_test.exs ---
defmodule AshA2A.C1W5.ReplayExactPreparedTest do
  use ExUnit.Case, async: true

  test "replay_exact_prepared" do
    p = Path.join([File.cwd!(), "priv", "sa2a", "c1", "w5_vectors", "replay_exact_prepared.json"])
    assert File.read!(p) =~ "\"sa2a-c1-w5-v1\""
  end
end

# --- SECTION 15: Original test/ash_a2a/c1_w5/same_claim_refused_test.exs ---
defmodule AshA2A.C1W5.SameClaimRefusedTest do
  use ExUnit.Case, async: true

  test "same_claim_refused" do
    p = Path.join([File.cwd!(), "priv", "sa2a", "c1", "w5_vectors", "same_claim_refused.json"])
    assert File.read!(p) =~ "\"sa2a-c1-w5-v1\""
  end
end

# --- SECTION 16: Original test/ash_a2a/c1_w5/standing_complete_test.exs ---
defmodule AshA2A.C1W5.StandingCompleteTest do
  use ExUnit.Case, async: true

  test "standing_complete" do
    p = Path.join([File.cwd!(), "priv", "sa2a", "c1", "w5_vectors", "standing_complete.json"])
    assert File.read!(p) =~ "\"sa2a-c1-w5-v1\""
  end
end

# --- SECTION 17: Original test/ash_a2a/c1_w5/standing_refused_test.exs ---
defmodule AshA2A.C1W5.StandingRefusedTest do
  use ExUnit.Case, async: true

  test "standing_refused" do
    p = Path.join([File.cwd!(), "priv", "sa2a", "c1", "w5_vectors", "standing_refused.json"])
    assert File.read!(p) =~ "\"sa2a-c1-w5-v1\""
  end
end

# --- SECTION 18: Original test/ash_a2a/c1_w5/standing_unknown_test.exs ---
defmodule AshA2A.C1W5.StandingUnknownTest do
  use ExUnit.Case, async: true

  test "standing_unknown" do
    p = Path.join([File.cwd!(), "priv", "sa2a", "c1", "w5_vectors", "standing_unknown.json"])
    assert File.read!(p) =~ "\"sa2a-c1-w5-v1\""
  end
end

# --- SECTION 19: Original test/ash_a2a/c1_w5/unknown_no_retry_test.exs ---
defmodule AshA2A.C1W5.UnknownNoRetryTest do
  use ExUnit.Case, async: true

  test "unknown_no_retry" do
    p = Path.join([File.cwd!(), "priv", "sa2a", "c1", "w5_vectors", "unknown_no_retry.json"])
    assert File.read!(p) =~ "\"sa2a-c1-w5-v1\""
  end
end

# --- SECTION 20: Original test/ash_a2a/c1_w5/unknown_reconcile_test.exs ---
defmodule AshA2A.C1W5.UnknownReconcileTest do
  use ExUnit.Case, async: true

  test "unknown_reconcile" do
    p = Path.join([File.cwd!(), "priv", "sa2a", "c1", "w5_vectors", "unknown_reconcile.json"])
    assert File.read!(p) =~ "\"sa2a-c1-w5-v1\""
  end
end
