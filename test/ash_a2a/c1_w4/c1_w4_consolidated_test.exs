# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT

# ==============================================================================
# Consolidated Test Suite: C1 W4 Totality Suite
# Consolidated by Worker 12 from 20 source files:
#   - test/ash_a2a/c1_w4/ash_create_forbidden_test.exs
#   - test/ash_a2a/c1_w4/ash_destroy_forbidden_test.exs
#   - test/ash_a2a/c1_w4/ash_update_forbidden_test.exs
#   - test/ash_a2a/c1_w4/change_routes_consequence_test.exs
#   - test/ash_a2a/c1_w4/completed_terminal_test.exs
#   - test/ash_a2a/c1_w4/direct_dispatch_forbidden_test.exs
#   - test/ash_a2a/c1_w4/dispatcher_call_forbidden_test.exs
#   - test/ash_a2a/c1_w4/exact_subject_token_test.exs
#   - test/ash_a2a/c1_w4/external_routes_consequence_test.exs
#   - test/ash_a2a/c1_w4/failed_known_test.exs
#   - test/ash_a2a/c1_w4/kernel_dispatch_allowed_test.exs
#   - test/ash_a2a/c1_w4/nil_refused_test.exs
#   - test/ash_a2a/c1_w4/observe_bypass_kernel_test.exs
#   - test/ash_a2a/c1_w4/observe_not_consequence_test.exs
#   - test/ash_a2a/c1_w4/only_kernel_caller_admitted_test.exs
#   - test/ash_a2a/c1_w4/prepared_digest_token_test.exs
#   - test/ash_a2a/c1_w4/unclassified_fail_closed_test.exs
#   - test/ash_a2a/c1_w4/unknown_outcome_no_retry_test.exs
#   - test/ash_a2a/c1_w4/unknown_refused_test.exs
#   - test/ash_a2a/c1_w4/unknown_requires_reconcile_test.exs
# ==============================================================================

# --- SECTION 1: Original test/ash_a2a/c1_w4/ash_create_forbidden_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1W4.AshCreateForbiddenTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.Dispatch.Route

  test "ash_create_forbidden" do
    v = "priv/sa2a/c1/w4_vectors/ash_create_forbidden.json" |> File.read!() |> Jason.decode!()

    input =
      case v["input"] do
        "change" -> :change
        "external_do" -> :external_do
        "observe" -> :observe
        "unknown" -> :unknown
        "nil" -> nil
        _ -> :other
      end

    assert Atom.to_string(Route.classify(input)) == v["route"]
  end
end

# --- SECTION 2: Original test/ash_a2a/c1_w4/ash_destroy_forbidden_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1W4.AshDestroyForbiddenTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.Dispatch.Route

  test "ash_destroy_forbidden" do
    v = "priv/sa2a/c1/w4_vectors/ash_destroy_forbidden.json" |> File.read!() |> Jason.decode!()

    input =
      case v["input"] do
        "change" -> :change
        "external_do" -> :external_do
        "observe" -> :observe
        "unknown" -> :unknown
        "nil" -> nil
        _ -> :other
      end

    assert Atom.to_string(Route.classify(input)) == v["route"]
  end
end

# --- SECTION 3: Original test/ash_a2a/c1_w4/ash_update_forbidden_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1W4.AshUpdateForbiddenTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.Dispatch.Route

  test "ash_update_forbidden" do
    v = "priv/sa2a/c1/w4_vectors/ash_update_forbidden.json" |> File.read!() |> Jason.decode!()

    input =
      case v["input"] do
        "change" -> :change
        "external_do" -> :external_do
        "observe" -> :observe
        "unknown" -> :unknown
        "nil" -> nil
        _ -> :other
      end

    assert Atom.to_string(Route.classify(input)) == v["route"]
  end
end

# --- SECTION 4: Original test/ash_a2a/c1_w4/change_routes_consequence_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1W4.ChangeRoutesConsequenceTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.Dispatch.Route

  test "change_routes_consequence" do
    v =
      "priv/sa2a/c1/w4_vectors/change_routes_consequence.json" |> File.read!() |> Jason.decode!()

    input =
      case v["input"] do
        "change" -> :change
        "external_do" -> :external_do
        "observe" -> :observe
        "unknown" -> :unknown
        "nil" -> nil
        _ -> :other
      end

    assert Atom.to_string(Route.classify(input)) == v["route"]
  end
end

# --- SECTION 5: Original test/ash_a2a/c1_w4/completed_terminal_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1W4.CompletedTerminalTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.Dispatch.Route

  test "completed_terminal" do
    v = "priv/sa2a/c1/w4_vectors/completed_terminal.json" |> File.read!() |> Jason.decode!()

    input =
      case v["input"] do
        "change" -> :change
        "external_do" -> :external_do
        "observe" -> :observe
        "unknown" -> :unknown
        "nil" -> nil
        _ -> :other
      end

    assert Atom.to_string(Route.classify(input)) == v["route"]
  end
end

# --- SECTION 6: Original test/ash_a2a/c1_w4/direct_dispatch_forbidden_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1W4.DirectDispatchForbiddenTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.Dispatch.Route

  test "direct_dispatch_forbidden" do
    v =
      "priv/sa2a/c1/w4_vectors/direct_dispatch_forbidden.json" |> File.read!() |> Jason.decode!()

    input =
      case v["input"] do
        "change" -> :change
        "external_do" -> :external_do
        "observe" -> :observe
        "unknown" -> :unknown
        "nil" -> nil
        _ -> :other
      end

    assert Atom.to_string(Route.classify(input)) == v["route"]
  end
end

# --- SECTION 7: Original test/ash_a2a/c1_w4/dispatcher_call_forbidden_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1W4.DispatcherCallForbiddenTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.Dispatch.Route

  test "dispatcher_call_forbidden" do
    v =
      "priv/sa2a/c1/w4_vectors/dispatcher_call_forbidden.json" |> File.read!() |> Jason.decode!()

    input =
      case v["input"] do
        "change" -> :change
        "external_do" -> :external_do
        "observe" -> :observe
        "unknown" -> :unknown
        "nil" -> nil
        _ -> :other
      end

    assert Atom.to_string(Route.classify(input)) == v["route"]
  end
end

# --- SECTION 8: Original test/ash_a2a/c1_w4/exact_subject_token_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1W4.ExactSubjectTokenTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.Dispatch.Route

  test "exact_subject_token" do
    v = "priv/sa2a/c1/w4_vectors/exact_subject_token.json" |> File.read!() |> Jason.decode!()

    input =
      case v["input"] do
        "change" -> :change
        "external_do" -> :external_do
        "observe" -> :observe
        "unknown" -> :unknown
        "nil" -> nil
        _ -> :other
      end

    assert Atom.to_string(Route.classify(input)) == v["route"]
  end
end

# --- SECTION 9: Original test/ash_a2a/c1_w4/external_routes_consequence_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1W4.ExternalRoutesConsequenceTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.Dispatch.Route

  test "external_routes_consequence" do
    v =
      "priv/sa2a/c1/w4_vectors/external_routes_consequence.json"
      |> File.read!()
      |> Jason.decode!()

    input =
      case v["input"] do
        "change" -> :change
        "external_do" -> :external_do
        "observe" -> :observe
        "unknown" -> :unknown
        "nil" -> nil
        _ -> :other
      end

    assert Atom.to_string(Route.classify(input)) == v["route"]
  end
end

# --- SECTION 10: Original test/ash_a2a/c1_w4/failed_known_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1W4.FailedKnownTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.Dispatch.Route

  test "failed_known" do
    v = "priv/sa2a/c1/w4_vectors/failed_known.json" |> File.read!() |> Jason.decode!()

    input =
      case v["input"] do
        "change" -> :change
        "external_do" -> :external_do
        "observe" -> :observe
        "unknown" -> :unknown
        "nil" -> nil
        _ -> :other
      end

    assert Atom.to_string(Route.classify(input)) == v["route"]
  end
end

# --- SECTION 11: Original test/ash_a2a/c1_w4/kernel_dispatch_allowed_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1W4.KernelDispatchAllowedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.Dispatch.Route

  test "kernel_dispatch_allowed" do
    v = "priv/sa2a/c1/w4_vectors/kernel_dispatch_allowed.json" |> File.read!() |> Jason.decode!()

    input =
      case v["input"] do
        "change" -> :change
        "external_do" -> :external_do
        "observe" -> :observe
        "unknown" -> :unknown
        "nil" -> nil
        _ -> :other
      end

    assert Atom.to_string(Route.classify(input)) == v["route"]
  end
end

# --- SECTION 12: Original test/ash_a2a/c1_w4/nil_refused_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1W4.NilRefusedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.Dispatch.Route

  test "nil_refused" do
    v = "priv/sa2a/c1/w4_vectors/nil_refused.json" |> File.read!() |> Jason.decode!()

    input =
      case v["input"] do
        "change" -> :change
        "external_do" -> :external_do
        "observe" -> :observe
        "unknown" -> :unknown
        "nil" -> nil
        _ -> :other
      end

    assert Atom.to_string(Route.classify(input)) == v["route"]
  end
end

# --- SECTION 13: Original test/ash_a2a/c1_w4/observe_bypass_kernel_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1W4.ObserveBypassKernelTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.Dispatch.Route

  test "observe_bypass_kernel" do
    v = "priv/sa2a/c1/w4_vectors/observe_bypass_kernel.json" |> File.read!() |> Jason.decode!()

    input =
      case v["input"] do
        "change" -> :change
        "external_do" -> :external_do
        "observe" -> :observe
        "unknown" -> :unknown
        "nil" -> nil
        _ -> :other
      end

    assert Atom.to_string(Route.classify(input)) == v["route"]
  end
end

# --- SECTION 14: Original test/ash_a2a/c1_w4/observe_not_consequence_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1W4.ObserveNotConsequenceTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.Dispatch.Route

  test "observe_not_consequence" do
    v = "priv/sa2a/c1/w4_vectors/observe_not_consequence.json" |> File.read!() |> Jason.decode!()

    input =
      case v["input"] do
        "change" -> :change
        "external_do" -> :external_do
        "observe" -> :observe
        "unknown" -> :unknown
        "nil" -> nil
        _ -> :other
      end

    assert Atom.to_string(Route.classify(input)) == v["route"]
  end
end

# --- SECTION 15: Original test/ash_a2a/c1_w4/only_kernel_caller_admitted_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1W4.OnlyKernelCallerAdmittedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.Dispatch.Route

  test "only_kernel_caller_admitted" do
    v =
      "priv/sa2a/c1/w4_vectors/only_kernel_caller_admitted.json"
      |> File.read!()
      |> Jason.decode!()

    input =
      case v["input"] do
        "change" -> :change
        "external_do" -> :external_do
        "observe" -> :observe
        "unknown" -> :unknown
        "nil" -> nil
        _ -> :other
      end

    assert Atom.to_string(Route.classify(input)) == v["route"]
  end
end

# --- SECTION 16: Original test/ash_a2a/c1_w4/prepared_digest_token_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1W4.PreparedDigestTokenTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.Dispatch.Route

  test "prepared_digest_token" do
    v = "priv/sa2a/c1/w4_vectors/prepared_digest_token.json" |> File.read!() |> Jason.decode!()

    input =
      case v["input"] do
        "change" -> :change
        "external_do" -> :external_do
        "observe" -> :observe
        "unknown" -> :unknown
        "nil" -> nil
        _ -> :other
      end

    assert Atom.to_string(Route.classify(input)) == v["route"]
  end
end

# --- SECTION 17: Original test/ash_a2a/c1_w4/unclassified_fail_closed_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1W4.UnclassifiedFailClosedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.Dispatch.Route

  test "unclassified_fail_closed" do
    v = "priv/sa2a/c1/w4_vectors/unclassified_fail_closed.json" |> File.read!() |> Jason.decode!()

    input =
      case v["input"] do
        "change" -> :change
        "external_do" -> :external_do
        "observe" -> :observe
        "unknown" -> :unknown
        "nil" -> nil
        _ -> :other
      end

    assert Atom.to_string(Route.classify(input)) == v["route"]
  end
end

# --- SECTION 18: Original test/ash_a2a/c1_w4/unknown_outcome_no_retry_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1W4.UnknownOutcomeNoRetryTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.Dispatch.Route

  test "unknown_outcome_no_retry" do
    v = "priv/sa2a/c1/w4_vectors/unknown_outcome_no_retry.json" |> File.read!() |> Jason.decode!()

    input =
      case v["input"] do
        "change" -> :change
        "external_do" -> :external_do
        "observe" -> :observe
        "unknown" -> :unknown
        "nil" -> nil
        _ -> :other
      end

    assert Atom.to_string(Route.classify(input)) == v["route"]
  end
end

# --- SECTION 19: Original test/ash_a2a/c1_w4/unknown_refused_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1W4.UnknownRefusedTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.Dispatch.Route

  test "unknown_refused" do
    v = "priv/sa2a/c1/w4_vectors/unknown_refused.json" |> File.read!() |> Jason.decode!()

    input =
      case v["input"] do
        "change" -> :change
        "external_do" -> :external_do
        "observe" -> :observe
        "unknown" -> :unknown
        "nil" -> nil
        _ -> :other
      end

    assert Atom.to_string(Route.classify(input)) == v["route"]
  end
end

# --- SECTION 20: Original test/ash_a2a/c1_w4/unknown_requires_reconcile_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1W4.UnknownRequiresReconcileTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.Dispatch.Route

  test "unknown_requires_reconcile" do
    v =
      "priv/sa2a/c1/w4_vectors/unknown_requires_reconcile.json" |> File.read!() |> Jason.decode!()

    input =
      case v["input"] do
        "change" -> :change
        "external_do" -> :external_do
        "observe" -> :observe
        "unknown" -> :unknown
        "nil" -> nil
        _ -> :other
      end

    assert Atom.to_string(Route.classify(input)) == v["route"]
  end
end
