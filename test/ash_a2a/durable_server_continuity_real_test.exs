# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.DurableServerContinuityRealTest do
  @moduledoc """
  Mainline continuity assertions against the REAL `DurableServer.Supervisor`
  (Elixir sweep queue item 2).

  `test/ash_a2a/durable_server_continuity_test.exs` ported its mainline
  continuity cases to `AshA2A.Test.FakeDurableServerSupervisor`, a
  same-process `Agent`-backed simulation. Per the sweep's lawful split,
  the fake stays ONLY for fault injection (`simulate_restart/2` /
  `simulate_node_loss/2` -- behaviors the real supervisor does not
  expose); the mainline cases move here and run against the real
  supervisor + real EKV backend, using the same pattern already proven
  in-test by `AshA2A.DurableServerRealRestartTest` and
  `AshA2A.Test.RestartableDurableServerFixture`.

  What changed relative to the fake's mainline cases, stated precisely:

  - "restart preserves stable TaskID key and durable state": the fake's
    `simulate_restart/2` (a plain `generation + 1` map update -- no real
    process ever died) is replaced by a REAL untrappable
    `Process.exit(pid, :kill)` recovered by the REAL
    `DurableServer.LifecycleManager` discovery-and-restart sweep. Key
    stability is asserted through the real lookup surface; durable state
    is asserted by reading the recovered count back from the real
    EKV-backed storage via the restarted process -- never re-supplied by
    this test.
  - "node loss is observable and rehome is separately receipted": the
    fake's `simulate_node_loss/2` leg is fault injection and STAYS in the
    fake file. What moves here is the rehome mainline: `rehome_child/3`
    on the real supervisor terminates the running process and starts it
    on the best-available node (single-node here, so `Node.self()`),
    recovering durable state from real storage. This is the single-node
    analogue only -- real cross-node rehome remains BLOCKED here (would
    need a second real distributed BEAM node), same scope note as
    `AshA2A.DurableServerRealRestartTest`.
  """
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.Durability.DurableServer, as: Durability
  alias AshA2A.Identity
  alias AshA2A.Test.RestartableDurableServerFixture, as: Fixture

  setup do
    sup_name =
      :"ash_a2a_test_continuity_real_sup_#{System.unique_integer([:positive])}"

    ekv_name = :"#{sup_name}_ekv"

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "ash_a2a_continuity_real_ekv_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(data_dir) end)

    # Real EKV local durable-KV backend, same pattern as
    # AshA2A.DurableServerRealRestartTest (cluster_size: 1 -- a real
    # single-voter CAS quorum).
    start_supervised!({EKV, name: ekv_name, data_dir: data_dir, cluster_size: 1})

    start_supervised!({
      DurableServer.Supervisor,
      # Real, documented DurableServer.Supervisor options, tightened from
      # production cadence so the real LifecycleManager sweep is observable
      # inside a normal test timeout (same rationale as
      # AshA2A.DurableServerRealRestartTest).
      name: sup_name,
      prefix: "ash-a2a-continuity-real-test/",
      backend: {DurableServer.Backends.EKVStore, name: ekv_name},
      initial_discovery_delay_ms: 100,
      discovery_interval_ms: 300,
      discovery_burst_count: 5
    })

    %{sup: sup_name}
  end

  test "restart preserves stable TaskID key and durable state (real supervisor, real LifecycleManager restart)",
       %{sup: sup} do
    task_id = Identity.task("continuity-real-restart-#{System.unique_integer([:positive])}")
    task_key = Durability.key(task_id)

    assert {:ok, receipt} =
             Durability.ensure_task(sup, Fixture, task_id, %{count: 7})

    assert receipt.provider == :durable_server
    assert receipt.operation == :ensure_started_child
    assert receipt.status == :completed

    # Stable TaskID key: the adapter's key derivation resolves the running
    # real process through the real supervisor's own lookup surface.
    assert {pid_before, _meta_before} = DurableServer.Supervisor.lookup(sup, task_key)
    assert is_pid(pid_before)
    assert Process.alive?(pid_before)
    assert GenServer.call(pid_before, :get) == 7

    # Mutate and rely on the fixture's `sync: true` so the state genuinely
    # reaches real EKV-backed storage before the kill.
    assert GenServer.call(pid_before, :increment) == 8
    assert GenServer.call(pid_before, :increment) == 9

    # REAL, untrappable termination (terminate/2 does not run on :kill).
    # No simulate_restart -- the real LifecycleManager's own
    # discovery-and-restart sweep (tightened above) brings the process back.
    ref = Process.monitor(pid_before)
    Process.exit(pid_before, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid_before, :killed}, 5_000
    refute Process.alive?(pid_before)

    restarted_pid = wait_until_restarted(sup, task_key, pid_before)

    assert is_pid(restarted_pid)
    assert restarted_pid != pid_before
    assert Process.alive?(restarted_pid)

    # Same stable TaskID key resolves to the new process; durable state is
    # read back from real storage (9 -- the last synced count), never
    # re-supplied by this test.
    assert {pid_after, _meta_after} = DurableServer.Supervisor.lookup(sup, task_key)
    assert pid_after == restarted_pid
    assert GenServer.call(restarted_pid, :get) == 9

    # The adapter's real-provider lookup passes the real supervisor's
    # success shape through: the TaskID key still resolves post-restart.
    assert {pid_via_adapter, _meta} = Durability.lookup(sup, task_id)
    assert pid_via_adapter == restarted_pid
  end

  test "rehome is separately receipted and recovers durable state (real supervisor, single-node)",
       %{sup: sup} do
    task_id = Identity.task("continuity-real-rehome-#{System.unique_integer([:positive])}")
    task_key = Durability.key(task_id)

    assert {:ok, _ensure_receipt} =
             Durability.ensure_task(sup, Fixture, task_id, %{count: 11})

    {pid_before, _meta_before} = DurableServer.Supervisor.lookup(sup, task_key)
    assert GenServer.call(pid_before, :increment) == 12

    assert {:ok, rehome_receipt} =
             Durability.rehome_task(sup, Fixture, task_id, %{count: 0}, [])

    assert rehome_receipt.provider == :durable_server
    assert rehome_receipt.operation == :rehome_child
    assert rehome_receipt.status == :completed

    # Rehome terminated the original process and started a genuinely new
    # one (single-node: on this node), under the same stable TaskID key.
    assert {pid_after, _meta_after} = DurableServer.Supervisor.lookup(sup, task_key)
    assert is_pid(pid_after)
    assert pid_after != pid_before
    assert not Process.alive?(pid_before)
    assert Process.alive?(pid_after)

    # Durable state recovered from real storage (12), not re-supplied via
    # the rehome's initial_state (%{count: 0}).
    assert GenServer.call(pid_after, :get) == 12
    assert GenServer.call(pid_after, :increment) == 13
  end

  defp wait_until_restarted(sup, key, original_pid) do
    deadline_ms = System.monotonic_time(:millisecond) + 10_000

    do_wait_until_restarted(sup, key, original_pid, deadline_ms)
  end

  defp do_wait_until_restarted(sup, key, original_pid, deadline_ms) do
    case DurableServer.Supervisor.lookup(sup, key) do
      {pid, _meta} when is_pid(pid) and pid != original_pid ->
        pid

      _other ->
        if System.monotonic_time(:millisecond) >= deadline_ms do
          flunk(
            "real DurableServer.LifecycleManager did not restart #{inspect(key)} under " <>
              "#{inspect(sup)} within the real polling deadline -- no genuinely new, live " <>
              "pid was observed via DurableServer.Supervisor.lookup/2"
          )
        end

        # Bounded poll on the real lookup observable.
        Process.sleep(50)
        do_wait_until_restarted(sup, key, original_pid, deadline_ms)
    end
  end
end
