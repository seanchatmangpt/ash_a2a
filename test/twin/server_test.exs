defmodule AshA2A.Twin.ServerTest do
  use ExUnit.Case, async: false

  alias AshA2A.Twin.{Asset, Operator, Partner, Server}

  setup do
    start_supervised!({AshA2A.Twin, [name: :"twin_srv_sup_#{System.unique_integer()}"]})
    :ok
  end

  defp uname(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"

  defp wait_until(fun, deadline_ms) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    poll(fun, deadline)
  end

  defp poll(fun, deadline) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) >= deadline -> flunk("condition not met in deadline")
      # SLEEP-CLASS: POLL-STEP (the audited deadline poll)
      true -> Process.sleep(10) && poll(fun, deadline)
    end
  end

  test "registration happens in the twin: name and Registry both resolve to its pid" do
    n = uname("asset")
    {:ok, pid} = AshA2A.Twin.start_twin(Asset, n)
    assert Process.whereis(n) == pid
    assert [{^pid, ^pid}] = Registry.lookup(AshA2A.Twin.Registry, n)
  end

  test "duplicate name: second start refused, no orphan, first twin untouched" do
    n = uname("asset")
    {:ok, first} = AshA2A.Twin.start_twin(Asset, n)
    before = AshA2A.Twin.count_twins()

    assert {:error, {^n, :already_registered}} = AshA2A.Twin.start_twin(Asset, n)

    assert AshA2A.Twin.count_twins() == before
    assert Process.whereis(n) == first
    assert Process.alive?(first)
    assert %{kind: :asset} = Asset.status(n)
  end

  test "duplicate name across kinds is also refused" do
    n = uname("shared")
    {:ok, _} = AshA2A.Twin.start_twin(Operator, n)
    assert {:error, {^n, :already_registered}} = AshA2A.Twin.start_twin(Partner, n)
  end

  test "registry entry disappears with the twin" do
    n = uname("op")
    {:ok, pid} = AshA2A.Twin.start_twin(Operator, n)
    ref = Process.monitor(pid)
    Operator.stop(n)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
    # Twins are :permanent children, so the supervisor may re-register a fresh
    # incarnation under the same name; the dead pid's entry must be gone.
    wait_until(
      fn ->
        match?([], Registry.lookup(AshA2A.Twin.Registry, n)) or
          match?([{new, _}] when new != pid, Registry.lookup(AshA2A.Twin.Registry, n))
      end,
      1_000
    )
  end

  test "peek on a non-operator replies a typed error instead of hanging" do
    a = uname("asset")
    p = uname("partner")
    {:ok, _} = AshA2A.Twin.start_twin(Asset, a)
    {:ok, _} = AshA2A.Twin.start_twin(Partner, p)
    assert {:error, {:wrong_kind, :asset}} = Server.call(a, {:peek, 3})
    assert {:error, {:wrong_kind, :partner}} = Server.call(p, {:peek, 3})
  end

  test "unknown call replies typed error on every kind" do
    for {mod, prefix} <- [{Asset, "a"}, {Partner, "p"}, {Operator, "o"}] do
      n = uname(prefix)
      {:ok, _} = AshA2A.Twin.start_twin(mod, n)
      assert {:error, :unknown_call} = Server.call(n, :bogus)
    end
  end

  test "operator peek rejects negative / non-integer n; zero is empty" do
    o = uname("op")
    {:ok, _} = AshA2A.Twin.start_twin(Operator, o)
    Operator.enqueue(o, :a)
    wait_until(fn -> Operator.status(o).depth == 1 end, 1_000)
    assert Operator.peek(o, 0) == []
    assert Operator.peek(o, -1) == {:error, :invalid_n}
    assert Operator.peek(o, :all) == {:error, :invalid_n}
    assert Operator.peek(o, 1) == [:a]
  end

  test "zero-dispersion spike trips an unacked dispatch (fail closed)" do
    p = uname("partner")
    {:ok, _} = AshA2A.Twin.start_twin(Partner, p, listener: self())
    Partner.shift_on(p)
    assert_receive {:shift_changed, ^p, :on_shift}, 1_000
    Enum.each([100, 100, 100, 100], &Partner.response(p, &1))
    Partner.dispatch(p, :job_flat)
    Partner.response(p, 5_000)

    assert_receive {:hazard_tripped, ^p, :infinity, %{dispatch: :job_flat, dispersion: :zero}},
                   1_000
  end

  test "zero-dispersion window with an equal observation does not trip" do
    p = uname("partner")
    {:ok, _} = AshA2A.Twin.start_twin(Partner, p, listener: self())
    Partner.shift_on(p)
    assert_receive {:shift_changed, ^p, :on_shift}, 1_000
    Enum.each([100, 100, 100, 100], &Partner.response(p, &1))
    Partner.dispatch(p, :job_flat)
    Partner.response(p, 100)
    # status call is a barrier: the cast above was processed before it replies
    assert %{window_size: 5} = Partner.status(p)
    refute_received {:hazard_tripped, _, _, _}
  end

  test "invalid twin name is refused at start" do
    Process.flag(:trap_exit, true)
    assert {:error, {nil, :invalid_name}} = Server.start_link(:asset, nil, [])
  end
end
