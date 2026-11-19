# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.GallClosure.LeaseGuardTest do
  use ExUnit.Case, async: true
  alias AshA2A.GallClosure.LeaseGuard

  test "bounded admission",
    do: assert(match?({:ok, _}, LeaseGuard.admit(%{lease_epoch: 7})))

  test "typed refusal", do: assert(LeaseGuard.admit(%{}) == {:error, :missing_lease})

  test "admits zero and positive epochs with guard tag" do
    assert {:ok, %{gall_guard: :lease_guard}} = LeaseGuard.admit(%{lease_epoch: 0})
    assert {:ok, _} = LeaseGuard.admit(%{lease_epoch: 42})
  end

  test "refuses negative and non-integer epochs" do
    for v <- [-1, "witness", "1", 1.0, true, nil, false, ""] do
      assert LeaseGuard.admit(%{lease_epoch: v}) == {:error, :missing_lease}
    end
  end

  describe "admit/2 value validation" do
    test "matching epoch admits" do
      assert {:ok, _} = LeaseGuard.admit(%{lease_epoch: 5}, %{epoch: 5})
    end

    test "stale epoch is refused" do
      assert LeaseGuard.admit(%{lease_epoch: 4}, %{epoch: 5}) ==
               {:refused_gall, :lease_guard, :stale_epoch}
    end

    test "epoch ahead of the authoritative lease is refused" do
      assert LeaseGuard.admit(%{lease_epoch: 6}, %{epoch: 5}) ==
               {:refused_gall, :lease_guard, :epoch_ahead}
    end

    test "expired, holder and scope mismatches are refused" do
      assert LeaseGuard.admit(%{lease_epoch: 5}, %{epoch: 5, expired: true}) ==
               {:refused_gall, :lease_guard, :expired}

      assert LeaseGuard.admit(%{lease_epoch: 5, holder: "a"}, %{epoch: 5, holder: "b"}) ==
               {:refused_gall, :lease_guard, :holder_mismatch}

      assert LeaseGuard.admit(%{lease_epoch: 5, scope: "x"}, %{epoch: 5, scope: "y"}) ==
               {:refused_gall, :lease_guard, :scope_mismatch}

      assert {:ok, _} =
               LeaseGuard.admit(%{lease_epoch: 5, holder: "a", scope: "x"}, %{
                 epoch: 5,
                 holder: "a",
                 scope: "x"
               })
    end

    test "missing lease is refused under an expectation; nil expectation is presence-only" do
      assert LeaseGuard.admit(%{}, %{epoch: 5}) == {:refused_gall, :lease_guard, :missing_lease}
      assert {:ok, _} = LeaseGuard.admit(%{lease_epoch: 1}, nil)
    end
  end
end
