defmodule AshA2A.Twin.LeaseTest do
  use ExUnit.Case, async: true

  alias AshA2A.Twin.Lease

  defp clock(t), do: [clock: {:mono, fn -> t end}]

  test "revoked lease cannot be renewed by nil holder or revoked again by nil" do
    {:ok, lease} = Lease.grant(:r, :h, 50, clock(1_000))
    {:ok, revoked} = Lease.revoke(lease, :h)
    assert revoked.holder == nil
    assert {:error, :not_holder} = Lease.renew(revoked, nil, 10, clock(1_001))
    assert {:error, :not_holder} = Lease.renew(revoked, :h, 10, clock(1_001))
    assert {:error, :not_holder} = Lease.revoke(revoked, nil)
    refute Lease.held?(revoked, nil, clock(1_001))
    assert Lease.expired?(revoked, nil, clock(1_001))
    # force still lawful
    assert {:ok, _} = Lease.revoke(revoked, :force)
  end

  test "renew refuses an expired (zombie) lease; boundary is exclusive" do
    {:ok, lease} = Lease.grant(:r, :h, 50, clock(1_000))
    assert {:ok, r} = Lease.renew(lease, :h, 10, clock(1_049))
    assert r.lease_until == 1_059
    assert {:error, :expired} = Lease.renew(lease, :h, 10, clock(1_050))
    assert {:error, :expired} = Lease.renew(lease, :h, 10, clock(5_000))
  end

  test "malformed clocks are typed not-held, never a crash" do
    {:ok, lease} = Lease.grant(:r, :h, 50, clock(1_000))

    for bad <- [
          nil,
          :wall,
          {:mono, nil},
          {:mono, fn -> :nope end},
          {:mono, fn -> nil end},
          {:mono, fn _ -> 1 end},
          {:mono, fn -> raise "boom" end}
        ] do
      opts = [clock: bad]
      refute Lease.held?(lease, :h, opts)
      assert Lease.expired?(lease, :h, opts)
      assert {:error, :invalid_clock} = Lease.grant(:r, :h, 5, opts)
      assert {:error, :invalid_clock} = Lease.renew(lease, :h, 5, opts)
    end

    assert_raise ArgumentError, fn -> Lease.clock_now(clock: nil) end
  end

  test "numeric guards: non-number and non-positive durations are typed" do
    for d <- [0, -1, 0.0, nil, "5", :x] do
      assert {:error, :invalid_duration} = Lease.grant(:r, :h, d, clock(1))
    end

    {:ok, lease} = Lease.grant(:r, :h, 50, clock(1))
    assert {:error, :invalid_duration} = Lease.renew(lease, :h, nil, clock(2))
    assert {:error, :invalid_duration} = Lease.renew(lease, :h, 0, clock(2))
  end

  test "holder nil never held even when granted to nil" do
    {:ok, lease} = Lease.grant(:r, nil, 50, clock(1))
    refute Lease.held?(lease, nil, clock(2))
    assert {:error, :not_holder} = Lease.renew(lease, nil, 5, clock(2))
  end
end
