# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Enterprise.DrainCourtTest do
  @moduledoc """
  FR-04 two-phase DRAIN court: real OS `SIGTERM`, real peer OS processes,
  real HTTP, real on-disk EKV, zero mocks.

  The court boots a REAL supervised tree (durable `AshA2A.TaskStore.Ekv`,
  `AshA2A.Cluster.DrainManager`, a real `Task.Supervisor`, and a real
  Bandit HTTP listener serving `AshA2A.Cluster.HealthPlug`) inside a real,
  separate OS process (`:peer.start/1` node "A"), runs REAL in-flight tasks
  on it, and sends a REAL operating-system `kill -TERM` to that OS process.

  Witnessed, in order:

    * **Cordon** (ARD budget 0-3s): a real HTTP `GET /healthz` is answered
      `503` with `retry-after: 30`; a new task's `track/3` is refused with
      `{:error, :cordoned}`; an in-flight task that concludes inside the
      drain window completes (existing tasks continue, new work rejected).
    * **Drain**: a task still running at the `drain_timeout_ms` deadline has
      its execution frame checkpointed into the on-disk EKV instance and a
      `[:ash_a2a, :cluster, :handover]` telemetry event really fires
      (forwarded cross-node to this test process). The worker is then
      stopped -- eviction, not abandonment.
    * **Clean exit**: node A's OS process is really gone within the 28s
      budget measured from `kill -TERM` (Kubernetes SIGKILLs at 30s); the
      measured timings are printed as part of the court record.
    * **Zero-drop rehydration**: a FRESH node OS process ("C") against the
      SAME `:data_dir` finds the checkpointed task via
      `AshA2A.Cluster.Handover.rehydrate/2`, resumes it from its stored
      frame, and completes it. Zero-drop is proven by a real side-effect
      ledger: every workload step is appended exactly once to a progress
      file -- steps 1-2 executed on node A before the drain, steps 3-4 by
      the fresh node -- and the final ledger is exactly all four steps.

  Every collaborator is real (Chicago discipline): the EKV store, the peer
  OS processes, the OS signal, the HTTP surface, and the durable checkpoint
  storage. No `Mox`/`:meck`/stub appears anywhere.

  Tagged `:serial` (real OS processes and distribution; `mix test.all` /
  `mix test.serial` run it).
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag timeout: 240_000

  alias AshA2A.Cluster.Checkpoint
  alias AshA2A.Cluster.DrainManager
  alias AshA2A.Cluster.Handover

  # Textually the nested module is defined below; alias it up front so the
  # test bodies above expand to the full nested name.
  alias AshA2A.Test.DrainCourtPeer

  @retry_after "30"
  @total_budget_ms 28_000
  @cordon_budget_ms 3_000
  @all_steps ["s1", "s2", "s3", "s4"]

  # ------------------------------------------------------------------
  # The full court: real OS SIGTERM against a real peer OS process
  # ------------------------------------------------------------------

  test "real SIGTERM drains a real node: cordon 503, in-flight completes, straggler checkpoints, clean exit <= 28s, fresh node rehydrates with zero drop" do
    ensure_distribution()

    base = court_dir("court")
    data_dir = Path.join(base, "ekv-data")
    progress = Path.join(base, "progress.log")
    port_a = free_port()

    # Node A: the real OS process that will receive the real SIGTERM.
    {peer_a, node_a} = start_peer("a")
    on_exit(fn -> File.rm_rf!(base) end)

    try do
      run_court(node_a, port_a, data_dir, progress)
    after
      DrainCourtPeer.stop_peer(peer_a)
    end
  end

  defp run_court(node_a, port_a, data_dir, progress) do
    tree_a =
      :erpc.call(node_a, DrainCourtPeer, :start_tree, [
        %{
          data_dir: data_dir,
          http_port: port_a,
          drain_timeout_ms: 3_000,
          forwarder: DrainCourtPeer.start_event_forwarder(node_a, self())
        }
      ])

    dm_a = tree_a.drain_manager

    # Before cordon: the real HTTP surface serves 200 on /healthz (poll
    # until the peer's listener is accepting, then demand 200).
    now = System.monotonic_time(:millisecond)
    assert {200, _headers, _body} = poll_healthz_until(port_a, 200, 10_000, now)

    # Two real in-flight tasks under the peer's real Task.Supervisor.
    fast = :erpc.call(node_a, DrainCourtPeer, :run_task, [tree_a, "fast", progress, self()])
    slow = :erpc.call(node_a, DrainCourtPeer, :run_task, [tree_a, "slow", progress, self()])

    assert {:ok, ["fast", "slow"]} = :erpc.call(node_a, DrainManager, :tracked, [dm_a])

    # The slow task makes real progress before the drain: steps 1-2.
    assert {:ok, %{done: ["s1"], remaining: ["s2", "s3", "s4"]}} = drive_step(slow, "s1")
    assert {:ok, %{done: ["s1", "s2"], remaining: ["s3", "s4"]}} = drive_step(slow, "s2")

    # A real operating-system signal to the real peer OS process.
    os_pid = :erpc.call(node_a, :os, :getpid, [])
    t_kill = System.monotonic_time(:millisecond)
    assert {_, 0} = System.cmd("kill", ["-TERM", to_string(os_pid)])

    assert {503, headers, _body} = poll_healthz_until(port_a, 503, @cordon_budget_ms, t_kill)

    assert {"retry-after", @retry_after} in headers

    cordon_ms = System.monotonic_time(:millisecond) - t_kill

    # New work is refused; the refusal is typed.
    assert {:error, :cordoned} = :erpc.call(node_a, DrainManager, :track, [dm_a, "late-task", []])

    # Existing work continues: the fast task finishes inside the window.
    send(fast.pid, {:drain_court, :finish, self()})
    assert_receive {:drain_court_finished, "fast", ^node_a}, 5_000

    # -- Phase 2: the deadline passes; the straggler is checkpointed, the
    #    handover event fires, and Phase 3 halts the OS process for real.
    wait_until(25_000, fn -> node_a not in Node.list() end)
    t_gone = System.monotonic_time(:millisecond)
    total_ms = t_gone - t_kill

    assert total_ms <= @total_budget_ms,
           "drain took #{total_ms}ms; budget is #{@total_budget_ms}ms"

    assert_receive {:drain_court_handover, %{task_id: "slow", reason: :drain}}, 5_000

    report(%{
      kill_to_cordon_ms: cordon_ms,
      kill_to_exit_ms: total_ms,
      budget_ms: @total_budget_ms
    })

    # -- Zero-drop: fresh node OS process, same data_dir -----------------
    {peer_c, node_c} = start_peer("c")

    try do
      tree_c =
        :erpc.call(node_c, DrainCourtPeer, :start_tree, [
          %{
            data_dir: data_dir,
            http_port: free_port(),
            drain_timeout_ms: 25_000,
            forwarder: nil
          }
        ])

      store_c = tree_c.store_tuple

      # A fresh, uncordoned node serves health again.
      assert {200, _headers, _body} = get_healthz(tree_c.http_port)

      {:ok, [entry]} =
        :erpc.call(node_c, Handover, :rehydrate, [
          store_c,
          :erpc.call(node_c, DrainCourtPeer, :resume_fun, [progress])
        ])

      assert entry.task_id == "slow"
      assert %{done: done, resumed_on: resumed_node} = entry.result
      assert done == @all_steps
      assert resumed_node == node_c

      # Durable task state: completed, envelope cleared, result recorded.
      assert {:ok, task} =
               :erpc.call(node_c, AshA2A.TaskStore.Ekv, :get, [tree_c.store_name, "slow"])

      assert task.status.state == :completed
      assert :error = :erpc.call(node_c, Checkpoint, :envelope, [task])
      assert {:ok, %{done: @all_steps}} = :erpc.call(node_c, Handover, :result, [task])

      # The real side-effect ledger: every step executed exactly once.
      # s1-s2 were executed on node A pre-drain; s3-s4 on fresh node C.
      assert progress_ledger(progress) == @all_steps
    after
      DrainCourtPeer.stop_peer(peer_c)
    end
  end

  # ------------------------------------------------------------------
  # Local courts: message-delivered :sigterm, defaults, round-trip
  # ------------------------------------------------------------------

  test "drain completes early when tracked work finishes; finishers are not checkpointed; cordoned track is refused" do
    ctx = start_local_tree()

    # A real task under a real Task.Supervisor that finishes quickly.
    {:ok, worker} =
      Task.Supervisor.start_child(ctx.task_supervisor, fn ->
        :ok = DrainManager.track(ctx.drain_manager, "quick", frame: %{done: [], remaining: []})
        send(ctx.report_to, :quick_tracked)
        Process.sleep(50)
        File.write!(ctx.quick_flag, "1")
        :ok = DrainManager.release(ctx.drain_manager, "quick")
      end)

    assert_receive :quick_tracked, 5_000
    assert {:ok, ["quick"]} = DrainManager.tracked(ctx.drain_manager)

    # `send(dm, :sigterm)` is the exact message the OS signal handler
    # delivers on SIGTERM (whose OS-level delivery the peer court above
    # witnesses against a real OS process).
    dm = ctx.drain_manager
    dm_pid = GenServer.whereis(dm)
    drain_ref = Process.monitor(dm_pid)
    t0 = System.monotonic_time(:millisecond)
    send(dm, :sigterm)

    # Cordon is immediate: new work is refused with the typed reason.
    assert {:error, :cordoned} = DrainManager.track(ctx.drain_manager, "late", [])

    assert_receive {:DOWN, ^drain_ref, :process, ^dm_pid, :shutdown}, 15_000
    elapsed = System.monotonic_time(:millisecond) - t0

    # The drain concluded on the finisher, not on the 25s deadline.
    assert elapsed < 10_000, "drain took #{elapsed}ms; should end when work finishes"

    # The finisher really finished and was NOT checkpointed.
    assert File.exists?(ctx.quick_flag)
    assert {:ok, []} = Handover.list_checkpointed(ctx.store)
  end

  test "defaults match FR-04/ARD 3.4" do
    ctx = start_local_tree()

    status = DrainManager.status(ctx.drain_manager)

    assert status.phase == :serving
    assert status.drain_timeout_ms == 25_000
    assert status.retry_after_s == 30
    assert status.exit_grace_ms == 2_000
    assert status.halt_after_drain == false
    assert status.cordoned? == false
    assert status.tracked == []
    assert {:ok, false} = DrainManager.cordoned?(ctx.drain_manager)
  end

  test "checkpoint + rehydrate round-trip on a real on-disk EKV store" do
    base = court_dir("checkpoint")
    on_exit(fn -> File.rm_rf!(base) end)

    data_dir = Path.join(base, "ekv-data")
    store_name = :"store_drain_court_ckpt_#{System.unique_integer([:positive])}"

    start_supervised!(AshA2A.TaskStore.Ekv.child_spec(name: store_name, data_dir: data_dir))
    store = {AshA2A.TaskStore.Ekv, store_name}

    # land(): synthesizes the task when the store has never seen it.
    checkpointed =
      Checkpoint.land(store, "rehydrate-me", %{done: ["a"], remaining: ["b"]},
        reason: :drain_deadline
      )

    assert Checkpoint.checkpointed?(checkpointed)

    assert {:ok, envelope} = Checkpoint.envelope(checkpointed)
    assert envelope["frame"] == %{done: ["a"], remaining: ["b"]}
    assert envelope["reason"] == :drain_deadline
    assert envelope["version"] == 1
    assert envelope["source_node"] == node()

    {:ok, [task]} = Handover.list_checkpointed(store)
    assert task.id == "rehydrate-me"

    {:ok, [entry]} =
      Handover.rehydrate(store, fn _task, frame -> {:ok, frame.done ++ frame.remaining} end)

    assert entry.task_id == "rehydrate-me"
    assert entry.result == ["a", "b"]

    assert {:ok, completed} = AshA2A.TaskStore.Ekv.get(store_name, "rehydrate-me")
    assert completed.status.state == :completed
    assert :error = Checkpoint.envelope(completed)
    assert {:ok, ["a", "b"]} = Handover.result(completed)

    # Idempotent: nothing left to rehydrate.
    assert {:ok, []} = Handover.rehydrate(store, fn _t, _f -> {:ok, :x} end)

    # A failing resume keeps the task suspended and adoptable.
    Checkpoint.land(store, "rehydrate-me-2", %{done: [], remaining: ["z"]})

    assert {:error, [failure]} =
             Handover.rehydrate(store, fn _t, _f -> {:error, :adopt_refused} end)

    assert failure.task_id == "rehydrate-me-2"

    {:ok, [still_suspended]} = Handover.list_checkpointed(store)
    assert still_suspended.id == "rehydrate-me-2"
  end

  # ------------------------------------------------------------------
  # Primary-side helpers
  # ------------------------------------------------------------------

  defp ensure_distribution do
    System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)

    unless Node.alive?() do
      name = :"drain_court_primary_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Node.start(name, :shortnames)
      on_exit(fn -> if Node.alive?(), do: Node.stop() end)
    end

    :ok
  end

  defp start_peer(suffix) do
    cookie = Node.get_cookie()

    host =
      Node.self() |> Atom.to_string() |> String.split("@") |> List.last() |> String.to_charlist()

    {:ok, peer_pid, node} =
      :peer.start(%{
        name: :"drain_court_#{suffix}_#{System.unique_integer([:positive])}",
        host: host,
        # A loaded full-suite run can exceed :peer's 15s default boot wait.
        wait_boot: 60_000,
        args: [~c"-setcookie", Atom.to_charlist(cookie)]
      })

    # On-demand code loading for AshA2A.* / Bandit / the test-support
    # fixture beams on the peer -- the same real mechanism the multinode
    # cluster test uses (test/support compiles to real on-disk beams).
    assert :ok = :rpc.call(node, :code, :add_pathsz, [:code.get_path()])
    assert {:module, _} = :rpc.call(node, :code, :ensure_loaded, [AshA2A.Test.DrainCourtPeer])

    {peer_pid, node}
  end

  defp drive_step(task, _step) do
    task_id = task.task_id
    send(task.pid, {:drain_court, :step, self()})
    assert_receive {:drain_court_stepped, ^task_id, {:ok, frame}}, 5_000
    {:ok, frame}
  end

  # curl, not :httpc: inets' httpc does not surface a 503+Retry-After
  # response to the caller -- it schedules an automatic retry and blocks
  # for the Retry-After period. curl returns the real response bytes.
  defp get_healthz(port) do
    {raw, 0} = System.cmd("curl", ["-s", "-i", "-m", "3", "http://127.0.0.1:#{port}/healthz"])

    [head | rest] = String.split(raw, "\r\n\r\n", parts: 2)
    body = Enum.join(rest, "\r\n\r\n")

    [status_line | header_lines] = String.split(head, "\r\n")
    status = parse_status(status_line)

    headers =
      for line <- header_lines,
          [k, v] = String.split(line, ":", parts: 2) do
        {String.downcase(String.trim(k)), String.trim(v)}
      end

    {status, headers, body}
  end

  defp parse_status(line) do
    case String.split(line, " ") do
      [_http_version, code | _rest] -> String.to_integer(code)
      _other -> 0
    end
  end

  defp poll_healthz_until(port, want_status, budget_ms, t0) do
    deadline = t0 + budget_ms

    poll_loop(port, want_status, deadline)
  end

  defp poll_loop(port, want_status, deadline) do
    now = System.monotonic_time(:millisecond)

    cond do
      now >= deadline ->
        raise ExUnit.AssertionError, "healthz never returned #{want_status} within budget"

      true ->
        case get_healthz(port) do
          {^want_status, _headers, _body} = hit ->
            hit

          _other ->
            Process.sleep(25)
            poll_loop(port, want_status, deadline)
        end
    end
  end

  defp progress_ledger(path) do
    path |> File.read!() |> String.split("\n", trim: true)
  end

  defp court_dir(name) do
    Path.join(
      System.tmp_dir!(),
      "ash_a2a_drain_court_#{name}_#{System.unique_integer([:positive])}"
    )
  end

  # Bind-probe in a NON-ephemeral range: ports from the OS ephemeral range
  # are routinely handed out as source ports to concurrent outbound
  # connections (httpc, :peer, distribution), and a listener that binds one
  # of those can shadow/conflict with the peer's Bandit listener, making
  # the court's HTTP witnesses unreliable.
  defp free_port do
    Enum.find_value(46_900..46_999, fn port ->
      case :gen_tcp.listen(port, [:binary, active: false, ip: {127, 0, 0, 1}]) do
        {:ok, socket} ->
          :gen_tcp.close(socket)
          port

        {:error, _in_use} ->
          nil
      end
    end) || raise ExUnit.AssertionError, "no free drain-court port in 46900..46999"
  end

  defp wait_until(timeout_ms, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    wait_loop(fun, deadline)
  end

  defp wait_loop(fun, deadline) do
    if fun.() do
      :ok
    else
      now = System.monotonic_time(:millisecond)

      if now >= deadline, do: raise(ExUnit.AssertionError, "condition not met within timeout")

      Process.sleep(50)
      wait_loop(fun, deadline)
    end
  end

  defp report(timings) do
    IO.puts([
      "\n[drain-court] FR-04 timings (real, measured):\n",
      "  kill -TERM -> 503 cordon witnessed : #{timings.kill_to_cordon_ms}ms (budget 3000ms)\n",
      "  kill -TERM -> OS process exited    : #{timings.kill_to_exit_ms}ms (budget #{timings.budget_ms}ms)\n"
    ])
  end

  defp start_local_tree do
    id = System.unique_integer([:positive])
    base = court_dir("local-#{id}")
    data_dir = Path.join(base, "ekv-data")
    on_exit(fn -> File.rm_rf!(base) end)

    store_name = :"store_drain_court_local_#{id}"
    dm_name = :"dm_drain_court_local_#{id}"
    sup_name = :"tasksup_drain_court_local_#{id}"

    start_supervised!({Task.Supervisor, name: sup_name})
    start_supervised!(AshA2A.TaskStore.Ekv.child_spec(name: store_name, data_dir: data_dir))

    start_supervised!({
      DrainManager,
      name: dm_name,
      task_supervisor: sup_name,
      task_store: {AshA2A.TaskStore.Ekv, store_name},
      install_signal_handler: false
    })

    %{
      drain_manager: dm_name,
      store: {AshA2A.TaskStore.Ekv, store_name},
      data_dir: data_dir,
      task_supervisor: sup_name,
      report_to: self(),
      quick_flag: Path.join(base, "quick-finished")
    }
  end
end
