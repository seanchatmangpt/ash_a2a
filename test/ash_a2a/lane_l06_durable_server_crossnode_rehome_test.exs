# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.LaneL06DurableServerCrossnodeRehomeTest do
  @moduledoc """
  Lane L06 -- cross-node rehome evidence for `AshA2A.Durability.DurableServer`.

  STATUS: UNVERIFIED. Written without an Elixir toolchain and without
  `deps/durable_server` available to read; it has not been compiled or run.

  Topology (same `:peer` pattern as `receipt_store_ekv_crossnode_test.exs`):
  the test node and one real `:peer` OS-process node each run a member of a
  two-voter EKV cluster and a `DurableServer.Supervisor` sharing one name,
  prefix and EKV backend. A task is ensured ON THE PEER through the adapter,
  then rehomed from THIS node through the adapter, so the real supervisor
  must terminate a process that lives on a different node.

  Asserted: the rehome is receipted, the old remote pid is dead, a new live
  pid resolves under the same TaskID key, and durable state (not the rehome's
  `initial_state`) is recovered. NOT asserted: which node the new pid lands
  on -- placement is provider state (see the adapter moduledoc), so the test
  only requires it to be a cluster member and reports it in the failure text.
  LifecycleManager orphan-claim after a peer crash is not exercised here.
  """
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_solo
  alias AshA2A.Durability.DurableServer, as: Durability
  alias AshA2A.Identity
  alias AshA2A.Test.LaneL06DurableServerPeerOwner, as: Owner
  alias AshA2A.Test.RestartableDurableServerFixture, as: Fixture

  setup_all do
    System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)
    already_alive? = Node.alive?()

    unless already_alive? do
      {:ok, _pid} = Node.start(:"ash_a2a_l06_primary_#{System.pid()}", :shortnames)
    end

    on_exit(fn ->
      if not already_alive? and Node.alive?(), do: Node.stop()
    end)

    :ok
  end

  test "rehome from one node terminates a task living on another node and recovers durable state" do
    host = Node.self() |> Atom.to_string() |> String.split("@") |> List.last() |> String.to_charlist()

    {:ok, peer_pid, peer_node} =
      :peer.start_link(%{
        name: :"ash_a2a_l06_peer_#{System.unique_integer([:positive, :monotonic])}",
        host: host,
        args: [~c"-setcookie", Atom.to_charlist(Node.get_cookie())]
      })

    try do
      assert :ok = :rpc.call(peer_node, :code, :add_pathsz, [:code.get_path()])

      uniq = System.unique_integer([:positive])
      sup_name = :"ash_a2a_l06_sup_#{uniq}"
      ekv_name = :"ash_a2a_l06_ekv_#{uniq}"
      dir_local = Path.join(System.tmp_dir!(), "ash_a2a_l06_local_#{uniq}")
      dir_peer = Path.join(System.tmp_dir!(), "ash_a2a_l06_peer_#{uniq}")
      on_exit(fn -> File.rm_rf!(dir_local) end)
      on_exit(fn -> File.rm_rf!(dir_peer) end)

      ekv_base = [name: ekv_name, cluster_size: 2, wait_for_quorum: :timer.seconds(25)]

      sup_opts = [
        name: sup_name,
        prefix: "ash-a2a-l06-crossnode/",
        backend: {DurableServer.Backends.EKVStore, name: ekv_name},
        initial_discovery_delay_ms: 100,
        discovery_interval_ms: 300,
        discovery_burst_count: 5
      ]

      test_pid = self()

      # Peer first: quorum needs both voters, so the peer member must already be
      # starting when this node's member blocks on wait_for_quorum.
      Node.spawn(peer_node, Owner, :start_and_wait, [
        Keyword.put(ekv_base, :data_dir, dir_peer),
        sup_opts,
        test_pid
      ])

      start_supervised!({EKV, Keyword.put(ekv_base, :data_dir, dir_local)})
      start_supervised!({DurableServer.Supervisor, sup_opts})

      receive do
        {:l06_peer_started, ^peer_node, _sup} -> :ok
        {:l06_peer_start_failed, ^peer_node, reason} -> flunk("peer start failed: #{inspect(reason)}")
      after
        30_000 -> flunk("peer did not report ready within 30s")
      end

      task_id = Identity.task("l06-crossnode-rehome-#{uniq}")
      task_key = Durability.key(task_id)

      # Ensure ON THE PEER through the adapter.
      assert {:ok, ensure_receipt} =
               :erpc.call(
                 peer_node,
                 Durability,
                 :ensure_task,
                 [sup_name, Fixture, task_id, %{count: 5}],
                 30_000
               )

      assert ensure_receipt.operation == :ensure_started_child
      assert ensure_receipt.status == :completed

      # The remote placement must be visible from THIS node through the adapter.
      assert eventually(fn ->
               match?({pid, _} when is_pid(pid), Durability.lookup(sup_name, task_id))
             end),
             "task ensured on the peer never became visible from the primary node"

      {pid_before, _meta} = Durability.lookup(sup_name, task_id)
      assert node(pid_before) == peer_node
      assert GenServer.call(pid_before, :increment) == 6

      # Rehome from THIS node: the supervisor must stop a process on the peer.
      assert {:ok, rehome_receipt} =
               Durability.rehome_task(sup_name, Fixture, task_id, %{count: 0}, [])

      assert rehome_receipt.provider == :durable_server
      assert rehome_receipt.operation == :rehome_child
      assert rehome_receipt.status == :completed

      assert eventually(fn ->
               match?({pid, _} when is_pid(pid) and pid != pid_before,
                      Durability.lookup(sup_name, task_id))
             end),
             "no new pid resolved under #{inspect(task_key)} after cross-node rehome"

      {pid_after, _meta} = Durability.lookup(sup_name, task_id)

      refute :erpc.call(node(pid_before), Process, :alive?, [pid_before], 5_000)
      assert :erpc.call(node(pid_after), Process, :alive?, [pid_after], 5_000)

      assert node(pid_after) in [node(), peer_node],
             "rehomed pid landed on unexpected node #{inspect(node(pid_after))}"

      # Durable state recovered from storage (6), not the rehome initial_state (0).
      assert GenServer.call(pid_after, :get) == 6
      assert GenServer.call(pid_after, :increment) == 7
    after
      if Process.alive?(peer_pid), do: :peer.stop(peer_pid)
    end
  end

  defp eventually(fun, attempts \\ 100, sleep_ms \\ 100)
  defp eventually(_fun, 0, _sleep_ms), do: false

  defp eventually(fun, attempts, sleep_ms) do
    if fun.() do
      true
    else
      Process.sleep(sleep_ms)
      eventually(fun, attempts - 1, sleep_ms)
    end
  end
end
