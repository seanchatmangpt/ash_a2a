defmodule AshA2A.PlanningHddlSolverCrossvmTest do
  @moduledoc """
  Reproduction of the v26.9.17 multinode-stress defect: `HddlSolver`
  cross-VM temp-file collision. TWO real `:peer` BEAM nodes (same real
  `:peer.start_link/1` + `:code.add_pathsz/1` pattern
  `test/ash_a2a/multinode_cluster_test.exs` established) each drive the real
  `AshA2A.Planning.HddlSolver.solve/3` -- real temp files + real
  `native/hddl_cli` OS subprocess -- CONCURRENTLY, one with a genuinely
  solvable pair, the other with a genuinely unsolvable one, and each node's
  real outcomes must stay consistent with ITS OWN inputs.

  The defect, precisely: `System.unique_integer/1` is documented unique "for
  the current VM instance" only. Two FRESH peer VMs' monotonic counters both
  start at the same value, and both VMs resolve the same `System.tmp_dir!/0`
  (a `:peer` node is a child OS process inheriting the parent's
  environment), so same-sequence invocations on both nodes derive the SAME
  absolute temp paths. The concurrent `File.write!/2` + `File.rm/1` pairs
  then overwrite/delete each other's files mid-solve: the solvable node's
  solver reads the unsolvable node's bytes (or its file vanishes before the
  subprocess opens it), flipping real outcomes across VMs.

  ## What is forced, disclosed plainly

  * The wall-clock start barrier (`AshA2A.Test.HddlSolverCrossvmDispatch`)
  synchronizes both peers' first solve to the same millisecond on this
  shared host -- in the production stress shape the contention was organic;
  here it is forced so the test is deterministic rather than load-dependent.
  * `tmp_dir` is passed explicitly to both peers so the collision is
  hermetic and the directory cleanup is owned by this test. This matches
  production (both nodes would share the OS tmp dir anyway); nothing about
  the paths themselves is forced -- the old node-blind
  `System.unique_integer` naming must collide all by itself.

  Per the ticket's fail-before gate this test failed against the unfixed
  `HddlSolver` (cross-contaminated outcomes across the two peers); the
  per-node unique temp-path fix in `HddlSolver.run/4` makes both peers'
  paths disjoint and this green.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Test.HddlSolverCrossvmDispatch

  @cli_path Path.expand("../native/hddl_cli/target/release/hddl_cli", __DIR__)

  @solvable_domain Path.expand("support/hddl/freedom_gym_meeting/domain.hddl", __DIR__)
  @solvable_problem Path.expand("support/hddl/freedom_gym_meeting/problem.hddl", __DIR__)

  @unsolvable_domain Path.expand("support/hddl/unsolvable_qualification/domain.hddl", __DIR__)
  @unsolvable_problem Path.expand("support/hddl/unsolvable_qualification/problem.hddl", __DIR__)

  # Enough same-sequence iterations that both peers' unique_integer
  # sequences overlap for several pairs even if one side drifts ahead.
  @iterations 8

  setup_all do
    unless File.exists?(@cli_path) do
      flunk("""
      hddl_cli binary not built at #{@cli_path}.
      Run: cd #{Path.expand("../native/hddl_cli", __DIR__)} && cargo build --release --locked
      """)
    end

    # Real, idempotent -- same defensive epmd + distributed-primary pattern
    # `AshA2A.MultinodeClusterTest` uses, so this file is self-sufficient
    # when run in isolation.
    System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)

    already_alive? = Node.alive?()

    unless already_alive? do
      primary_name = :"ash_a2a_hddl_crossvm_primary_#{System.pid()}"
      {:ok, _pid} = Node.start(primary_name, :shortnames)
    end

    on_exit(fn ->
      if not already_alive? and Node.alive?() do
        Node.stop()
      end
    end)

    :ok
  end

  setup do
    %{cookie: Node.get_cookie(), host: peer_host(), code_paths: :code.get_path()}
  end

  defp peer_host do
    Node.self() |> Atom.to_string() |> String.split("@") |> List.last() |> String.to_charlist()
  end

  defp start_real_peer(host, cookie, code_paths) do
    peer_name = :"ash_a2a_hddl_crossvm_peer_#{System.unique_integer([:positive, :monotonic])}"

    start_opts = %{
      name: peer_name,
      host: host,
      args: [~c"-setcookie", Atom.to_charlist(cookie)]
    }

    {:ok, peer_pid, peer_node} = :peer.start_link(start_opts)

    assert :ok = :rpc.call(peer_node, :code, :add_pathsz, [code_paths])

    {peer_pid, peer_node}
  end

  # Same real, empirically-found teardown constraint
  # `AshA2A.MultinodeClusterTest` documents: `:peer.stop/1` must run on the
  # same process that called `:peer.start_link/1`, so teardown lives in this
  # test body's `try/after`, never in `on_exit/1`.
  defp stop_if_alive(peer_pid) do
    if Process.alive?(peer_pid) do
      :peer.stop(peer_pid)
    end

    :ok
  end

  @tag :crossvm_hddl
  test "two concurrent peer VMs solving different HDDL pairs get outcomes consistent with their OWN inputs (no cross-VM temp-file collision)",
       %{cookie: cookie, host: host, code_paths: code_paths} do
    {pid_a, node_a} = start_real_peer(host, cookie, code_paths)
    {pid_b, node_b} = start_real_peer(host, cookie, code_paths)

    # Hermetic, explicitly-shared temp dir -- identical to the production
    # shape (peer child processes inherit the parent's OS tmp dir); see this
    # module's @moduledoc "What is forced".
    tmp_dir =
      Path.join(System.tmp_dir!(), "ash_a2a_hddl_crossvm_repro_#{System.unique_integer()}")

    File.mkdir_p!(tmp_dir)

    try do
      assert node_a != node_b

      solvable_domain = File.read!(@solvable_domain)
      solvable_problem = File.read!(@solvable_problem)
      unsolvable_domain = File.read!(@unsolvable_domain)
      unsolvable_problem = File.read!(@unsolvable_problem)

      # Real cross-node start barrier: one shared host wall clock.
      start_ms = System.system_time(:millisecond) + 2_000

      task_a =
        Task.async(fn ->
          :erpc.call(
            node_a,
            HddlSolverCrossvmDispatch,
            :solve_barrier_until,
            [start_ms, @iterations, tmp_dir, solvable_domain, solvable_problem],
            60_000
          )
        end)

      task_b =
        Task.async(fn ->
          :erpc.call(
            node_b,
            HddlSolverCrossvmDispatch,
            :solve_barrier_until,
            [start_ms, @iterations, tmp_dir, unsolvable_domain, unsolvable_problem],
            60_000
          )
        end)

      {solver_node_a, results_a} = Task.await(task_a, 60_000)
      {solver_node_b, results_b} = Task.await(task_b, 60_000)

      # Both sides really executed on their own distinct remote peers.
      assert solver_node_a == node_a and solver_node_a != node()
      assert solver_node_b == node_b and solver_node_b != node()
      assert solver_node_a != solver_node_b

      # Node A solved the genuinely solvable pair -- EVERY invocation must
      # have really solved. Under the old node-blind temp naming, node B's
      # concurrent unsolvable bytes (or B's mid-flight File.rm of the same
      # absolute path) surface here as {:error, :hddl_solve_error} /
      # {:error, :non_json_stdout}.
      assert results_a == List.duplicate({:ok, true}, @iterations),
             "node A (solvable pair) got cross-contaminated outcomes: #{inspect(results_a)}"

      # Node B classified the genuinely unsolvable pair -- EVERY invocation
      # must have really refused. Under the old naming, node A's concurrent
      # solvable bytes overwriting B's temp files surface here as
      # {:ok, true} -- a solve that never belonged to B's inputs.
      assert results_b == List.duplicate({:error, :hddl_solve_error}, @iterations),
             "node B (unsolvable pair) got cross-contaminated outcomes: #{inspect(results_b)}"

      # Cleanup discipline across BOTH VMs: every temp file every solve
      # wrote is really gone (each owner removed its own unique paths; the
      # old shared-path cleanup could not make this guarantee).
      leftover = Path.wildcard(Path.join(tmp_dir, "ash_a2a_hddl_*.hddl"))
      assert leftover == [], "leftover HddlSolver temp files: #{inspect(leftover)}"
    after
      File.rm_rf!(tmp_dir)
      stop_if_alive(pid_a)
      stop_if_alive(pid_b)
    end
  end
end
