# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT

# ==============================================================================
# Consolidated Test Suite: C1 Prepared Store
# Contains original tests:
#   - test/ash_a2a/c1_prepared_store/applying_claimed_test.exs
#   - test/ash_a2a/c1_prepared_store/applying_completed_test.exs
#   - test/ash_a2a/c1_prepared_store/applying_released_test.exs
#   - test/ash_a2a/c1_prepared_store/applying_unknown_test.exs
#   - test/ash_a2a/c1_prepared_store/claimed_applying_test.exs
#   - test/ash_a2a/c1_prepared_store/claimed_completed_test.exs
#   - test/ash_a2a/c1_prepared_store/claimed_released_test.exs
#   - test/ash_a2a/c1_prepared_store/claimed_unknown_test.exs
#   - test/ash_a2a/c1_prepared_store/compensated_applying_test.exs
#   - test/ash_a2a/c1_prepared_store/completed_applying_test.exs
#   - test/ash_a2a/c1_prepared_store/prepared_claimed_test.exs
#   - test/ash_a2a/c1_prepared_store/prepared_completed_test.exs
#   - test/ash_a2a/c1_prepared_store/prepared_refused_test.exs
#   - test/ash_a2a/c1_prepared_store/prepared_unknown_test.exs
#   - test/ash_a2a/c1_prepared_store/reconciled_applying_test.exs
#   - test/ash_a2a/c1_prepared_store/refused_claimed_test.exs
#   - test/ash_a2a/c1_prepared_store/released_applying_test.exs
#   - test/ash_a2a/c1_prepared_store/unknown_compensated_test.exs
#   - test/ash_a2a/c1_prepared_store/unknown_completed_test.exs
#   - test/ash_a2a/c1_prepared_store/unknown_reconciled_test.exs
# ==============================================================================

# --- SECTION 1: Original test/ash_a2a/c1_prepared_store/applying_claimed_test.exs ---
defmodule AshA2A.C1PreparedStore.ApplyingClaimedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  test "applying_claimed",
    do: assert(Transition.admit(:applying, :claimed) == {:error, :prepared_transition_refused})
end

# --- SECTION 2: Original test/ash_a2a/c1_prepared_store/applying_completed_test.exs ---
defmodule AshA2A.C1PreparedStore.ApplyingCompletedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition
  test "applying_completed", do: assert(Transition.admit(:applying, :completed) == :ok)
end

# --- SECTION 3: Original test/ash_a2a/c1_prepared_store/applying_released_test.exs ---
defmodule AshA2A.C1PreparedStore.ApplyingReleasedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  test "applying_released",
    do: assert(Transition.admit(:applying, :released) == {:error, :prepared_transition_refused})
end

# --- SECTION 4: Original test/ash_a2a/c1_prepared_store/applying_unknown_test.exs ---
defmodule AshA2A.C1PreparedStore.ApplyingUnknownTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition
  test "applying_unknown", do: assert(Transition.admit(:applying, :unknown_outcome) == :ok)
end

# --- SECTION 5: Original test/ash_a2a/c1_prepared_store/claimed_applying_test.exs ---
defmodule AshA2A.C1PreparedStore.ClaimedApplyingTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition
  test "claimed_applying", do: assert(Transition.admit(:claimed, :applying) == :ok)
end

# --- SECTION 6: Original test/ash_a2a/c1_prepared_store/claimed_completed_test.exs ---
defmodule AshA2A.C1PreparedStore.ClaimedCompletedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  test "claimed_completed",
    do: assert(Transition.admit(:claimed, :completed) == {:error, :prepared_transition_refused})
end

# --- SECTION 7: Original test/ash_a2a/c1_prepared_store/claimed_released_test.exs ---
defmodule AshA2A.C1PreparedStore.ClaimedReleasedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition
  test "claimed_released", do: assert(Transition.admit(:claimed, :released) == :ok)
end

# --- SECTION 8: Original test/ash_a2a/c1_prepared_store/claimed_unknown_test.exs ---
defmodule AshA2A.C1PreparedStore.ClaimedUnknownTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  test "claimed_unknown",
    do:
      assert(
        Transition.admit(:claimed, :unknown_outcome) == {:error, :prepared_transition_refused}
      )
end

# --- SECTION 9: Original test/ash_a2a/c1_prepared_store/compensated_applying_test.exs ---
defmodule AshA2A.C1PreparedStore.CompensatedApplyingTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  test "compensated_applying",
    do:
      assert(Transition.admit(:compensated, :applying) == {:error, :prepared_transition_refused})
end

# --- SECTION 10: Original test/ash_a2a/c1_prepared_store/completed_applying_test.exs ---
defmodule AshA2A.C1PreparedStore.CompletedApplyingTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  test "completed_applying",
    do: assert(Transition.admit(:completed, :applying) == {:error, :prepared_transition_refused})
end

# --- SECTION 11: Original test/ash_a2a/c1_prepared_store/prepared_claimed_test.exs ---
defmodule AshA2A.C1PreparedStore.PreparedClaimedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition
  test "prepared_claimed", do: assert(Transition.admit(:prepared, :claimed) == :ok)
end

# --- SECTION 12: Original test/ash_a2a/c1_prepared_store/prepared_completed_test.exs ---
defmodule AshA2A.C1PreparedStore.PreparedCompletedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  test "prepared_completed",
    do: assert(Transition.admit(:prepared, :completed) == {:error, :prepared_transition_refused})
end

# --- SECTION 13: Original test/ash_a2a/c1_prepared_store/prepared_refused_test.exs ---
defmodule AshA2A.C1PreparedStore.PreparedRefusedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition
  test "prepared_refused", do: assert(Transition.admit(:prepared, :refused) == :ok)
end

# --- SECTION 14: Original test/ash_a2a/c1_prepared_store/prepared_unknown_test.exs ---
defmodule AshA2A.C1PreparedStore.PreparedUnknownTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  test "prepared_unknown",
    do:
      assert(
        Transition.admit(:prepared, :unknown_outcome) == {:error, :prepared_transition_refused}
      )
end

# --- SECTION 15: Original test/ash_a2a/c1_prepared_store/reconciled_applying_test.exs ---
defmodule AshA2A.C1PreparedStore.ReconciledApplyingTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  test "reconciled_applying",
    do: assert(Transition.admit(:reconciled, :applying) == {:error, :prepared_transition_refused})
end

# --- SECTION 16: Original test/ash_a2a/c1_prepared_store/refused_claimed_test.exs ---
defmodule AshA2A.C1PreparedStore.RefusedClaimedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  test "refused_claimed",
    do: assert(Transition.admit(:refused, :claimed) == {:error, :prepared_transition_refused})
end

# --- SECTION 17: Original test/ash_a2a/c1_prepared_store/released_applying_test.exs ---
defmodule AshA2A.C1PreparedStore.ReleasedApplyingTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  test "released_applying",
    do: assert(Transition.admit(:released, :applying) == {:error, :prepared_transition_refused})
end

# --- SECTION 18: Original test/ash_a2a/c1_prepared_store/unknown_compensated_test.exs ---
defmodule AshA2A.C1PreparedStore.UnknownCompensatedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition
  test "unknown_compensated", do: assert(Transition.admit(:unknown_outcome, :compensated) == :ok)
end

# --- SECTION 19: Original test/ash_a2a/c1_prepared_store/unknown_completed_test.exs ---
defmodule AshA2A.C1PreparedStore.UnknownCompletedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  test "unknown_completed",
    do:
      assert(
        Transition.admit(:unknown_outcome, :completed) == {:error, :prepared_transition_refused}
      )
end

# --- SECTION 20: Original test/ash_a2a/c1_prepared_store/unknown_reconciled_test.exs ---
defmodule AshA2A.C1PreparedStore.UnknownReconciledTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition
  test "unknown_reconciled", do: assert(Transition.admit(:unknown_outcome, :reconciled) == :ok)
end

