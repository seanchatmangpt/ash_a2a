defmodule AshA2A.DurableServerRealRestartTest do
  @moduledoc """
  GAP C -- real DurableServer restart evidence (Squad E agent 22).

  `test/ash_a2a/durable_server_continuity_test.exs`'s "restart preserves
  stable TaskID key and durable state" / "node loss is observable..."
  tests drive `AshA2A.Test.FakeDurableServerSupervisor`, a same-process
  `Agent`-backed simulation confirmed (by re-reading that file for this
  unit) still accurate as of this session: `simulate_restart/2` is a
  plain `%{runtime | generation: runtime.generation + 1}` map update and
  `simulate_node_loss/2` is a plain `Map.reject/2` over the Agent's own
  state -- no real OTP process ever dies, no real distributed node is
  ever involved. That file is intentionally left unextended here.

  This module instead drives the REAL `durable_server` hex dependency --
  the same real `DurableServer.Supervisor` + real `EKV` local backend
  already exercised by `AshA2A.RuntimeProvidersIntegrationTest`'s
  `Durability` describe block -- genuinely kills the real child
  `GenServer` process with `Process.exit(pid, :kill)`, and proves the
  real `DurableServer.LifecycleManager`'s own discovery-and-restart sweep
  (never a hand-rolled re-ensure/re-claim call from this test) detects
  the dead process and restarts it under real supervision, recovering
  real durably-synced state.

  ## What was actually read in `deps/durable_server` to ground this test

  - `lib/durable_server/lifecycle_manager.ex`: automatic restart only
    considers servers with `meta.permanent == true` (default `false`);
    `check_server_health/2` uses `Group.lookup/3` (the real `:syn`-style
    fast path) for liveness, falling back to
    `fetch_orphaned_slow_path/1` when the registry entry is gone.
  - `lib/durable_server.ex`: `check_lock_status/1`, for a key whose
    recorded owner node is the CURRENT node, calls `__check_lock__/3`
    directly, which does a real local `Process.alive?(pid)` check --
    same-node restart eligibility is therefore detected immediately on
    the next discovery sweep, not gated behind the ~30s cross-node
    heartbeat-staleness window. `DurableServer.Supervisor`'s own
    moduledoc documents `discovery_interval_ms`/
    `initial_discovery_delay_ms`/`discovery_burst_count` as real,
    supported `start_link/1` options ("With custom intervals" example) --
    this test tightens them from their 60s/1-6s/3 production defaults
    purely to make the real sweep observable inside a normal test
    timeout, not to bypass any real mechanic.
  - `lib/durable_server.ex` `child_spec/1`: sets `restart: :temporary` on
    the underlying `DynamicSupervisor` child spec, confirming that a
    plain OTP supervisor restart is NOT what recovers a killed
    DurableServer -- the `LifecycleManager` discovery/restart-claim path
    is the actual, real, documented recovery mechanism this test
    exercises.

  ## Scope, stated precisely (do not conflate with cross-node rehome)

  This is single-node. `DurableServer.LifecycleManager`'s restart path
  has a real cross-node orphan-claim path too (a second BEAM node erpc's
  in and claims the key when the recorded owner node's heartbeat goes
  stale), but this test does not start a second real distributed node, so
  it cannot and does not exercise or claim that path.
  Real standing, precisely:
  - real single-node LifecycleManager-driven restart-after-kill: ALIVE
    (this test).
  - real cross-node rehome/orphan-claim-by-another-node: BLOCKED here
    (would need a second real distributed BEAM node) -- see
    `AshA2A.DurableServerContinuityTest`'s `rehome_task/5` receipt path
    for the (still only simulated) analogue, left to a real
    distributed-peer-node unit.
  """
  use ExUnit.Case, async: false

  alias AshA2A.Durability.DurableServer, as: Durability
  alias AshA2A.Identity
  alias AshA2A.Test.RestartableDurableServerFixture, as: Fixture

  setup do
    sup_name = :"ash_a2a_test_real_restart_sup_#{System.unique_integer([:positive])}"
    ekv_name = :"#{sup_name}_ekv"

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "ash_a2a_real_restart_ekv_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(data_dir) end)

    # Same real EKV local durable-KV backend pattern as
    # AshA2A.RuntimeProvidersIntegrationTest's Durability describe block
    # (cluster_size: 1 -- a real single-voter CAS quorum).
    start_supervised!({EKV, name: ekv_name, data_dir: data_dir, cluster_size: 1})

    start_supervised!({
      DurableServer.Supervisor,
      # Real, documented DurableServer.Supervisor options (see its own
      # moduledoc "With custom intervals" example), tightened from the
      # 60_000ms / {1_000, 6_000}ms / 3 production defaults so this
      # test observes a real LifecycleManager restart sweep well inside
      # a normal test timeout instead of waiting on production cadence.
      name: sup_name,
      prefix: "ash-a2a-real-restart-test/",
      backend: {DurableServer.Backends.EKVStore, name: ekv_name},
      initial_discovery_delay_ms: 100,
      discovery_interval_ms: 300,
      discovery_burst_count: 5
    })

    %{sup: sup_name}
  end

  test "a real killed DurableServer-managed process is restarted by the real LifecycleManager and recovers real synced state",
       %{sup: sup} do
    task_id = Identity.new(:task, "real-restart-#{System.unique_integer([:positive])}")

    assert {:ok,
            %AshA2A.RuntimeReceipt{provider: :durable_server, operation: :ensure_started_child}} =
             Durability.ensure_task(sup, Fixture, task_id, %{count: 0})

    key = Durability.key(task_id)

    {original_pid, _meta} = DurableServer.Supervisor.lookup(sup, key)
    assert is_pid(original_pid)

    assert GenServer.call(original_pid, :get) == 0
    assert GenServer.call(original_pid, :increment) == 1
    assert GenServer.call(original_pid, :increment) == 2
    assert GenServer.call(original_pid, :increment) == 3

    # Real, untrappable termination. `terminate/2` does NOT run on
    # `:kill`, so anything not already durably synced above would be
    # lost -- only the `sync: true` on each :increment call (see
    # RestartableDurableServerFixture) gives the post-restart read-back
    # below any real durability to actually recover.
    ref = Process.monitor(original_pid)
    Process.exit(original_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^original_pid, :killed}, 5_000
    refute Process.alive?(original_pid)

    # No hand-rolled restart call from this test. Only the real
    # DurableServer.LifecycleManager's own discovery-and-restart sweep
    # (tightened above to run fast) is permitted to bring the process
    # back. Poll the same real DurableServer.Supervisor.lookup/2 surface
    # AshA2A.Durability.DurableServer/RuntimeProvidersIntegrationTest
    # already use, for a genuinely different, genuinely live pid.
    restarted_pid =
      wait_until_restarted(
        sup,
        key,
        original_pid,
        System.monotonic_time(:millisecond) + 10_000
      )

    assert is_pid(restarted_pid)
    assert restarted_pid != original_pid
    assert Process.alive?(restarted_pid)

    # Real recovered state: the last durably-synced count (3), read back
    # by the real post-restart init/1 from the real EKV-backed storage --
    # not re-supplied by this test.
    assert GenServer.call(restarted_pid, :get) == 3
  end

  defp wait_until_restarted(sup, key, original_pid, deadline_ms) do
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
        else
          Process.sleep(50)
          wait_until_restarted(sup, key, original_pid, deadline_ms)
        end
    end
  end
end
