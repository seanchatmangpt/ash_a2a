# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT

# ==============================================================================
# Consolidated Test Suite: C1 W3 Hardening
# Contains original tests:
#   - test/ash_a2a/c1_w3_hardening/applying_completed_test.exs
#   - test/ash_a2a/c1_w3_hardening/applying_released_test.exs
#   - test/ash_a2a/c1_w3_hardening/applying_unknown_test.exs
#   - test/ash_a2a/c1_w3_hardening/claimed_applying_test.exs
#   - test/ash_a2a/c1_w3_hardening/claimed_completed_test.exs
#   - test/ash_a2a/c1_w3_hardening/claimed_released_test.exs
#   - test/ash_a2a/c1_w3_hardening/claimed_unknown_test.exs
#   - test/ash_a2a/c1_w3_hardening/compensated_applying_test.exs
#   - test/ash_a2a/c1_w3_hardening/completed_applying_test.exs
#   - test/ash_a2a/c1_w3_hardening/completed_released_test.exs
#   - test/ash_a2a/c1_w3_hardening/prepared_applying_test.exs
#   - test/ash_a2a/c1_w3_hardening/prepared_claimed_test.exs
#   - test/ash_a2a/c1_w3_hardening/prepared_completed_test.exs
#   - test/ash_a2a/c1_w3_hardening/prepared_released_test.exs
#   - test/ash_a2a/c1_w3_hardening/reconciled_applying_test.exs
#   - test/ash_a2a/c1_w3_hardening/released_claimed_test.exs
#   - test/ash_a2a/c1_w3_hardening/unknown_compensated_test.exs
#   - test/ash_a2a/c1_w3_hardening/unknown_completed_test.exs
#   - test/ash_a2a/c1_w3_hardening/unknown_reconciled_test.exs
#   - test/ash_a2a/c1_w3_hardening/unknown_released_test.exs
# ==============================================================================

# --- SECTION 1: Original test/ash_a2a/c1_w3_hardening/applying_completed_test.exs ---
defmodule AshA2A.C1W3Hardening.ApplyingCompletedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  test "applying_completed transition court" do
    v =
      Path.join([File.cwd!(), "priv/sa2a/c1/w3_hardening_vectors/applying_completed.json"])
      |> File.read!()
      |> Jason.decode!()

    Code.ensure_loaded!(Transition)
    from = String.to_existing_atom(v["from"])
    to = String.to_existing_atom(v["to"])
    assert Transition.admit(from, to) == :ok == v["admit"]
  end
end

# --- SECTION 2: Original test/ash_a2a/c1_w3_hardening/applying_released_test.exs ---
defmodule AshA2A.C1W3Hardening.ApplyingReleasedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  test "applying_released transition court" do
    v =
      Path.join([File.cwd!(), "priv/sa2a/c1/w3_hardening_vectors/applying_released.json"])
      |> File.read!()
      |> Jason.decode!()

    Code.ensure_loaded!(Transition)
    from = String.to_existing_atom(v["from"])
    to = String.to_existing_atom(v["to"])
    assert Transition.admit(from, to) == :ok == v["admit"]
  end
end

# --- SECTION 3: Original test/ash_a2a/c1_w3_hardening/applying_unknown_test.exs ---
defmodule AshA2A.C1W3Hardening.ApplyingUnknownTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  test "applying_unknown transition court" do
    v =
      Path.join([File.cwd!(), "priv/sa2a/c1/w3_hardening_vectors/applying_unknown.json"])
      |> File.read!()
      |> Jason.decode!()

    Code.ensure_loaded!(Transition)
    from = String.to_existing_atom(v["from"])
    to = String.to_existing_atom(v["to"])
    assert Transition.admit(from, to) == :ok == v["admit"]
  end
end

# --- SECTION 4: Original test/ash_a2a/c1_w3_hardening/claimed_applying_test.exs ---
defmodule AshA2A.C1W3Hardening.ClaimedApplyingTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  test "claimed_applying transition court" do
    v =
      Path.join([File.cwd!(), "priv/sa2a/c1/w3_hardening_vectors/claimed_applying.json"])
      |> File.read!()
      |> Jason.decode!()

    Code.ensure_loaded!(Transition)
    from = String.to_existing_atom(v["from"])
    to = String.to_existing_atom(v["to"])
    assert Transition.admit(from, to) == :ok == v["admit"]
  end
end

# --- SECTION 5: Original test/ash_a2a/c1_w3_hardening/claimed_completed_test.exs ---
defmodule AshA2A.C1W3Hardening.ClaimedCompletedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  test "claimed_completed transition court" do
    v =
      Path.join([File.cwd!(), "priv/sa2a/c1/w3_hardening_vectors/claimed_completed.json"])
      |> File.read!()
      |> Jason.decode!()

    Code.ensure_loaded!(Transition)
    from = String.to_existing_atom(v["from"])
    to = String.to_existing_atom(v["to"])
    assert Transition.admit(from, to) == :ok == v["admit"]
  end
end

# --- SECTION 6: Original test/ash_a2a/c1_w3_hardening/claimed_released_test.exs ---
defmodule AshA2A.C1W3Hardening.ClaimedReleasedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  test "claimed_released transition court" do
    v =
      Path.join([File.cwd!(), "priv/sa2a/c1/w3_hardening_vectors/claimed_released.json"])
      |> File.read!()
      |> Jason.decode!()

    Code.ensure_loaded!(Transition)
    from = String.to_existing_atom(v["from"])
    to = String.to_existing_atom(v["to"])
    assert Transition.admit(from, to) == :ok == v["admit"]
  end
end

# --- SECTION 7: Original test/ash_a2a/c1_w3_hardening/claimed_unknown_test.exs ---
defmodule AshA2A.C1W3Hardening.ClaimedUnknownTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  test "claimed_unknown transition court" do
    v =
      Path.join([File.cwd!(), "priv/sa2a/c1/w3_hardening_vectors/claimed_unknown.json"])
      |> File.read!()
      |> Jason.decode!()

    Code.ensure_loaded!(Transition)
    from = String.to_existing_atom(v["from"])
    to = String.to_existing_atom(v["to"])
    assert Transition.admit(from, to) == :ok == v["admit"]
  end
end

# --- SECTION 8: Original test/ash_a2a/c1_w3_hardening/compensated_applying_test.exs ---
defmodule AshA2A.C1W3Hardening.CompensatedApplyingTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  test "compensated_applying transition court" do
    v =
      Path.join([File.cwd!(), "priv/sa2a/c1/w3_hardening_vectors/compensated_applying.json"])
      |> File.read!()
      |> Jason.decode!()

    Code.ensure_loaded!(Transition)
    from = String.to_existing_atom(v["from"])
    to = String.to_existing_atom(v["to"])
    assert Transition.admit(from, to) == :ok == v["admit"]
  end
end

# --- SECTION 9: Original test/ash_a2a/c1_w3_hardening/completed_applying_test.exs ---
defmodule AshA2A.C1W3Hardening.CompletedApplyingTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  test "completed_applying transition court" do
    v =
      Path.join([File.cwd!(), "priv/sa2a/c1/w3_hardening_vectors/completed_applying.json"])
      |> File.read!()
      |> Jason.decode!()

    Code.ensure_loaded!(Transition)
    from = String.to_existing_atom(v["from"])
    to = String.to_existing_atom(v["to"])
    assert Transition.admit(from, to) == :ok == v["admit"]
  end
end

# --- SECTION 10: Original test/ash_a2a/c1_w3_hardening/completed_released_test.exs ---
defmodule AshA2A.C1W3Hardening.CompletedReleasedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  test "completed_released transition court" do
    v =
      Path.join([File.cwd!(), "priv/sa2a/c1/w3_hardening_vectors/completed_released.json"])
      |> File.read!()
      |> Jason.decode!()

    Code.ensure_loaded!(Transition)
    from = String.to_existing_atom(v["from"])
    to = String.to_existing_atom(v["to"])
    assert Transition.admit(from, to) == :ok == v["admit"]
  end
end

# --- SECTION 11: Original test/ash_a2a/c1_w3_hardening/prepared_applying_test.exs ---
defmodule AshA2A.C1W3Hardening.PreparedApplyingTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  test "prepared_applying transition court" do
    v =
      Path.join([File.cwd!(), "priv/sa2a/c1/w3_hardening_vectors/prepared_applying.json"])
      |> File.read!()
      |> Jason.decode!()

    Code.ensure_loaded!(Transition)
    from = String.to_existing_atom(v["from"])
    to = String.to_existing_atom(v["to"])
    assert Transition.admit(from, to) == :ok == v["admit"]
  end
end

# --- SECTION 12: Original test/ash_a2a/c1_w3_hardening/prepared_claimed_test.exs ---
defmodule AshA2A.C1W3Hardening.PreparedClaimedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  test "prepared_claimed transition court" do
    v =
      Path.join([File.cwd!(), "priv/sa2a/c1/w3_hardening_vectors/prepared_claimed.json"])
      |> File.read!()
      |> Jason.decode!()

    Code.ensure_loaded!(Transition)
    from = String.to_existing_atom(v["from"])
    to = String.to_existing_atom(v["to"])
    assert Transition.admit(from, to) == :ok == v["admit"]
  end
end

# --- SECTION 13: Original test/ash_a2a/c1_w3_hardening/prepared_completed_test.exs ---
defmodule AshA2A.C1W3Hardening.PreparedCompletedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  test "prepared_completed transition court" do
    v =
      Path.join([File.cwd!(), "priv/sa2a/c1/w3_hardening_vectors/prepared_completed.json"])
      |> File.read!()
      |> Jason.decode!()

    Code.ensure_loaded!(Transition)
    from = String.to_existing_atom(v["from"])
    to = String.to_existing_atom(v["to"])
    assert Transition.admit(from, to) == :ok == v["admit"]
  end
end

# --- SECTION 14: Original test/ash_a2a/c1_w3_hardening/prepared_released_test.exs ---
defmodule AshA2A.C1W3Hardening.PreparedReleasedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  test "prepared_released transition court" do
    v =
      Path.join([File.cwd!(), "priv/sa2a/c1/w3_hardening_vectors/prepared_released.json"])
      |> File.read!()
      |> Jason.decode!()

    Code.ensure_loaded!(Transition)
    from = String.to_existing_atom(v["from"])
    to = String.to_existing_atom(v["to"])
    assert Transition.admit(from, to) == :ok == v["admit"]
  end
end

# --- SECTION 15: Original test/ash_a2a/c1_w3_hardening/reconciled_applying_test.exs ---
defmodule AshA2A.C1W3Hardening.ReconciledApplyingTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  test "reconciled_applying transition court" do
    v =
      Path.join([File.cwd!(), "priv/sa2a/c1/w3_hardening_vectors/reconciled_applying.json"])
      |> File.read!()
      |> Jason.decode!()

    Code.ensure_loaded!(Transition)
    from = String.to_existing_atom(v["from"])
    to = String.to_existing_atom(v["to"])
    assert Transition.admit(from, to) == :ok == v["admit"]
  end
end

# --- SECTION 16: Original test/ash_a2a/c1_w3_hardening/released_claimed_test.exs ---
defmodule AshA2A.C1W3Hardening.ReleasedClaimedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  test "released_claimed transition court" do
    v =
      Path.join([File.cwd!(), "priv/sa2a/c1/w3_hardening_vectors/released_claimed.json"])
      |> File.read!()
      |> Jason.decode!()

    Code.ensure_loaded!(Transition)
    from = String.to_existing_atom(v["from"])
    to = String.to_existing_atom(v["to"])
    assert Transition.admit(from, to) == :ok == v["admit"]
  end
end

# --- SECTION 17: Original test/ash_a2a/c1_w3_hardening/unknown_compensated_test.exs ---
defmodule AshA2A.C1W3Hardening.UnknownCompensatedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  test "unknown_compensated transition court" do
    v =
      Path.join([File.cwd!(), "priv/sa2a/c1/w3_hardening_vectors/unknown_compensated.json"])
      |> File.read!()
      |> Jason.decode!()

    Code.ensure_loaded!(Transition)
    from = String.to_existing_atom(v["from"])
    to = String.to_existing_atom(v["to"])
    assert Transition.admit(from, to) == :ok == v["admit"]
  end
end

# --- SECTION 18: Original test/ash_a2a/c1_w3_hardening/unknown_completed_test.exs ---
defmodule AshA2A.C1W3Hardening.UnknownCompletedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  test "unknown_completed transition court" do
    v =
      Path.join([File.cwd!(), "priv/sa2a/c1/w3_hardening_vectors/unknown_completed.json"])
      |> File.read!()
      |> Jason.decode!()

    Code.ensure_loaded!(Transition)
    from = String.to_existing_atom(v["from"])
    to = String.to_existing_atom(v["to"])
    assert Transition.admit(from, to) == :ok == v["admit"]
  end
end

# --- SECTION 19: Original test/ash_a2a/c1_w3_hardening/unknown_reconciled_test.exs ---
defmodule AshA2A.C1W3Hardening.UnknownReconciledTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  test "unknown_reconciled transition court" do
    v =
      Path.join([File.cwd!(), "priv/sa2a/c1/w3_hardening_vectors/unknown_reconciled.json"])
      |> File.read!()
      |> Jason.decode!()

    Code.ensure_loaded!(Transition)
    from = String.to_existing_atom(v["from"])
    to = String.to_existing_atom(v["to"])
    assert Transition.admit(from, to) == :ok == v["admit"]
  end
end

# --- SECTION 20: Original test/ash_a2a/c1_w3_hardening/unknown_released_test.exs ---
defmodule AshA2A.C1W3Hardening.UnknownReleasedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition

  test "unknown_released transition court" do
    v =
      Path.join([File.cwd!(), "priv/sa2a/c1/w3_hardening_vectors/unknown_released.json"])
      |> File.read!()
      |> Jason.decode!()

    Code.ensure_loaded!(Transition)
    from = String.to_existing_atom(v["from"])
    to = String.to_existing_atom(v["to"])
    assert Transition.admit(from, to) == :ok == v["admit"]
  end
end

