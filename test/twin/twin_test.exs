defmodule AshA2A.TwinTest do
  use ExUnit.Case, async: false

  alias AshA2A.Twin.{Asset, Hazard, Lease, Operator, Partner}

  setup do
    sup_name = :"twin_test_sup_#{System.unique_integer()}"
    start_supervised!({AshA2A.Twin, [name: sup_name]})
    :ok
  end

  # -- Hazard math: exact values on known windows ---------------------------

  test "median/MAD/z exact on a known window" do
    window = [100, 102, 98, 105, 95]
    assert Hazard.median(window) == 100.0
    # deviations [0,2,2,5,5] -> MAD 2.0
    assert Hazard.mad(window) == 2.0
    {:ok, z} = Hazard.zscore(106, window)
    assert z == 3.0
    assert Hazard.trip?(z, 2.5)
    refute Hazard.trip?(1.0, 2.5)
    # strictly greater: z == threshold does not trip
    refute Hazard.trip?(2.5, 2.5)
  end

  test "MAD == 0 -> typed insufficient_dispersion" do
    assert {:error, :insufficient_dispersion} = Hazard.zscore(50, [10, 10, 10])
    assert {:error, :insufficient_dispersion} = Hazard.zscore(50, [])
    assert {:error, :insufficient_dispersion} = Hazard.zscore(50, [7, 7, 7])
  end

  test "even-length median averages the two middle values" do
    assert Hazard.median([1, 2, 3, 4]) == 2.5
    assert Hazard.mad([1, 2, 3, 4]) == 1.0
  end

  test "ring buffer evicts oldest past capacity" do
    h = Hazard.new(3)
    h = Enum.reduce([1, 2, 3, 4, 5], h, fn x, h -> Hazard.push(h, x) end)
    assert Enum.sort(Hazard.window(h)) == [3, 4, 5]
  end

  test "observe pushes then estimates and returns the advanced monitor" do
    h = Hazard.new(4)
    h = Enum.reduce([10, 12, 8, 10], h, fn x, h -> Hazard.push(h, x) end)
    {:ok, stats} = Hazard.observe(h, 10)
    assert stats.median == 10.0
    assert is_float(stats.mad)
    assert is_number(stats.z)
    # pre-observation window semantics: monitor has the new obs prepended
    assert stats.monitor.buffer == Enum.take([10 | stats.window], 4)
    assert stats.trip? == Hazard.trip?(stats.z)
  end

  # -- Lease tests -----------------------------------------------------------

  test "grant/renew/expire/revoke with injected monotonic clock" do
    t0 = 1_000
    {:ok, lease} = Lease.grant(:res_a, :asset_1, 50, clock: {:mono, fn -> t0 end})
    assert lease.lease_until == t0 + 50
    assert Lease.held?(lease, :asset_1, clock: {:mono, fn -> t0 + 49 end})
    assert Lease.expired?(lease, :asset_1, clock: {:mono, fn -> t0 + 50 end})
    # zombie: expiry without renewal
    assert Lease.expired?(lease, :asset_1, clock: {:mono, fn -> t0 + 500 end})
    assert {:error, :invalid_duration} = Lease.grant(:x, :h, 0)
    assert {:error, :invalid_duration} = Lease.renew(lease, :asset_1, -5)
  end

  test "CAS: foreign claimant cannot renew; revoke only by holder or force" do
    t0 = 1_000
    {:ok, lease} = Lease.grant(:res_b, :asset_1, 50, clock: {:mono, fn -> t0 end})
    {:ok, r1} = Lease.renew(lease, :asset_1, 80, clock: {:mono, fn -> t0 + 10 end})
    assert r1.lease_until == t0 + 90
    assert r1.renewed_count == 1
    assert {:error, :not_holder} = Lease.renew(r1, :intruder, 10)
    assert {:error, :not_holder} = Lease.revoke(r1, :other)
    {:ok, revoked} = Lease.revoke(r1, :asset_1)
    assert Lease.expired?(revoked, :asset_1, clock: {:mono, fn -> t0 + 10 end})
  end

  test "real monotonic clock: fresh lease held, wrong holder expired, expiry is real" do
    {:ok, lease} = Lease.grant(:r, :h, :erlang.convert_time_unit(1, :millisecond, :native) * 5)
    assert Lease.held?(lease, :h)
    assert Lease.expired?(lease, :wrong_holder)
    wait_until(fn -> Lease.expired?(lease, :h) end, 2_000)
  end

  # -- Partner twin: hazard trip over a real gen_statem ----------------------

  test "partner trips hazard on unacknowledged slow response" do
    listener = self()
    pn = :"partner_#{System.unique_integer()}"
    {:ok, _} = AshA2A.Twin.start_twin(Partner, pn, listener: listener, threshold: 2.5)
    assert %{shift: :off_shift} = Partner.status(pn)

    Partner.shift_on(pn)
    assert_receive({:shift_changed, ^pn, :on_shift}, 1_000)
    Enum.each([100, 102, 98, 105, 95], &Partner.response(pn, &1))

    # dispatch stays unacknowledged; z = (106-100)/2 = 3.0 > 2.5 -> trip
    Partner.dispatch(pn, :job_42)
    Partner.response(pn, 106)
    assert_receive({:hazard_tripped, ^pn, 3.0, stats}, 1_000)
    assert stats.median == 100.0
    assert stats.mad == 2.0
    assert stats.dispatch == :job_42
  end

  test "ack suppresses trips until next dispatch; off-shift dispatch is ignored" do
    listener = self()
    pn2 = :"partner_#{System.unique_integer()}"
    {:ok, _} = AshA2A.Twin.start_twin(Partner, pn2, listener: listener, threshold: 2.5)
    Partner.shift_on(pn2)
    assert_receive({:shift_changed, ^pn2, :on_shift}, 1_000)
    Enum.each([100, 102, 98, 105, 95], &Partner.response(pn2, &1))
    Partner.dispatch(pn2, :job_43)
    Partner.ack(pn2)
    Partner.response(pn2, 106)
    refute_receive({:hazard_tripped, _, _, _}, 200)
    Partner.shift_off(pn2)
    assert_receive({:shift_changed, ^pn2, :off_shift}, 1_000)
    Partner.dispatch(pn2, :job_44)
    Partner.response(pn2, 120)
    refute_receive({:hazard_tripped, _, _, _}, 200)
  end

  # -- Asset SLA timer (real gen_statem timer, no sleep coordination) --------

  test "asset arms SLA on activity and fires expiry when not disarmed" do
    listener = self()
    an = :"asset_#{System.unique_integer()}"
    {:ok, _} = AshA2A.Twin.start_twin(Asset, an, listener: listener, sla_ms: 30)
    assert %{armed?: false, ops_count: 0} = Asset.status(an)

    Asset.record_activity(an, :run_1)

    wait_until(
      fn ->
        %{armed?: armed} = Asset.status(an)
        armed
      end,
      1_000
    )

    assert_receive({:sla_expired, ^an, %{ref: :run_1}}, 2_000)

    wait_until(
      fn ->
        %{armed?: armed} = Asset.status(an)
        not armed
      end,
      1_000
    )

    # disarm suppresses the countdown
    Asset.record_activity(an, :run_2)
    Asset.disarm(an)
    refute_receive({:sla_expired, ^an, %{ref: :run_2}}, 100)
  end

  # -- Operator queue + attention budget -------------------------------------

  test "operator dequeues in order, budget exhaustion emits event, recharge restores" do
    listener = self()
    on = :"operator_#{System.unique_integer()}"
    {:ok, _} = AshA2A.Twin.start_twin(Operator, on, listener: listener, budget: 2)
    assert %{depth: 0, budget: 2} = Operator.status(on)

    Operator.enqueue(on, :w1)
    Operator.enqueue(on, :w2)
    wait_until(fn -> Operator.status(on).depth == 2 end, 1_000)
    assert Operator.peek(on, 5) == [:w1, :w2]

    Operator.attend(on)
    Operator.attend(on)
    assert_receive({:budget_exhausted, ^on, %{depth: 0}}, 1_000)

    wait_until(
      fn ->
        %{depth: depth, budget: budget} = Operator.status(on)
        depth == 0 and budget == 0
      end,
      1_000
    )

    # fail-closed: attending at zero budget does nothing
    Operator.enqueue(on, :w3)
    Operator.attend(on)
    wait_until(fn -> Operator.status(on).depth == 1 end, 1_000)
    assert Operator.peek(on, 5) == [:w3]

    Operator.recharge(on)
    Operator.attend(on)

    wait_until(
      fn ->
        %{depth: depth, budget: budget} = Operator.status(on)
        depth == 0 and budget == 4
      end,
      1_000
    )
  end

  # -- Lifecycle: no orphan actors after supervisor shutdown -----------------

  test "twin lifecycle: all actors die with supervisor" do
    twins_before = AshA2A.Twin.count_twins()
    lan = :"asset_#{System.unique_integer()}"
    lpn = :"partner_#{System.unique_integer()}"
    {:ok, _} = AshA2A.Twin.start_twin(Asset, lan, sla_ms: 60_000)
    {:ok, _} = AshA2A.Twin.start_twin(Partner, lpn)
    wait_until(fn -> AshA2A.Twin.count_twins() == twins_before + 2 end, 1_000)
    assert Process.whereis(lan)
    assert Process.whereis(lpn)

    stop_supervisor()
    wait_until(fn -> AshA2A.Twin.count_twins() == 0 end, 2_000)
    refute Process.whereis(lan), "orphan asset twin after shutdown"
    refute Process.whereis(lpn), "orphan partner twin after shutdown"
  end

  defp stop_supervisor do
    case Process.whereis(AshA2A.Twin.TwinSupervisor) do
      nil -> :ok
      pid -> Supervisor.stop(pid)
    end
  end

  defp wait_until(fun, deadline_ms) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    check(fun, deadline)
  end

  defp check(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition not met within deadline")
      end

      Process.sleep(20)
      check(fun, deadline)
    end
  end
end
