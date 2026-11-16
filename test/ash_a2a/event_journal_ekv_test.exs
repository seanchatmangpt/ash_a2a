# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.EventJournalEkvTest do
  @moduledoc """
  `AshA2A.TaskStore.EventJournalEkv` against real on-disk `EKV` instances: one
  local instance, and a real two-peer `EKV` cluster (`:peer` nodes, same helper
  pattern as `AshA2A.ReceiptStoreEkvCrossnodeTest`) proving a journal written
  on node A replays on node B, which is the resubscribe-on-a-second-node gap.

  No mocks.
  """
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_solo

  alias AshA2A.Protocol.EventJournal
  alias AshA2A.Test.MultinodeEkvOwner
  alias AshA2A.TaskStore.EventJournalEkv

  describe "single node" do
    setup do
      id = System.unique_integer([:positive])
      name = :"ash_a2a_event_journal_ekv_test_#{id}"
      data_dir = Path.join(System.tmp_dir!(), "ash_a2a_event_journal_ekv_test_#{id}")
      File.rm_rf!(data_dir)
      on_exit(fn -> File.rm_rf!(data_dir) end)

      start_supervised!(AshA2A.TaskStore.Ekv.child_spec(name: name, data_dir: data_dir))
      %{journal: {EventJournalEkv, name}}
    end

    test "append/replay_after/trim round-trip in generation order", %{journal: j} do
      :ok = EventJournal.append(j, "t/1", 2, %{n: 3})
      :ok = EventJournal.append(j, "t/1", 1, %{n: 1})
      :ok = EventJournal.append(j, "t/1", 1, %{n: 2})
      :ok = EventJournal.append(j, "t/10", 1, :other_task)

      assert {:ok, [%{n: 1}, %{n: 2}, %{n: 3}]} = EventJournal.replay_after(j, "t/1", 0)
      assert {:ok, [%{n: 3}]} = EventJournal.replay_after(j, "t/1", 1)
      assert {:ok, [:other_task]} = EventJournal.replay_after(j, "t/10", 0)

      assert :ok = EventJournal.trim(j, "t/1", 1)
      assert {:ok, [%{n: 3}]} = EventJournal.replay_after(j, "t/1", 0)
      assert {:ok, [:other_task]} = EventJournal.replay_after(j, "t/10", 0)
    end

    test "concurrent appends are all stored", %{journal: j} do
      results =
        1..30
        |> Task.async_stream(fn n -> EventJournal.append(j, "t", 1, {:evt, n}) end,
          max_concurrency: 15
        )
        |> Enum.map(fn {:ok, r} -> r end)

      assert Enum.all?(results, &(&1 == :ok))
      assert {:ok, events} = EventJournal.replay_after(j, "t", 0)
      assert Enum.sort(events) == Enum.map(1..30, &{:evt, &1})
    end
  end

  describe "two real nodes" do
    setup do
      System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)
      already_alive? = Node.alive?()

      unless already_alive? do
        {:ok, _pid} = Node.start(:"ash_a2a_ejournal_primary_#{System.pid()}", :shortnames)
      end

      on_exit(fn -> if not already_alive? and Node.alive?(), do: Node.stop() end)
      :ok
    end

    test "events appended on node A replay on node B",
         _ctx do
      host = Node.self() |> Atom.to_string() |> String.split("@") |> List.last() |> String.to_charlist()
      cookie = Node.get_cookie()
      code_paths = :code.get_path()

      {peer_a, node_a} = start_real_peer(host, cookie, code_paths)
      {peer_b, node_b} = start_real_peer(host, cookie, code_paths)

      try do
        assert :erpc.call(node_a, Node, :ping, [node_b], 10_000) == :pong

        ekv_name = :"ash_a2a_ejournal_#{System.unique_integer([:positive, :monotonic])}"
        dir_a = Path.join(System.tmp_dir!(), "ash_a2a_ejournal_a_#{System.unique_integer([:positive])}")
        dir_b = Path.join(System.tmp_dir!(), "ash_a2a_ejournal_b_#{System.unique_integer([:positive])}")
        on_exit(fn -> File.rm_rf!(dir_a) end)
        on_exit(fn -> File.rm_rf!(dir_b) end)

        base = [name: ekv_name, cluster_size: 2, wait_for_quorum: :timer.seconds(25)]
        me = self()

        # Concurrent start: each member's quorum wait blocks until the other joins.
        Node.spawn(node_a, MultinodeEkvOwner, :start_ekv_member_and_wait, [
          Keyword.put(base, :data_dir, dir_a),
          me
        ])

        Node.spawn(node_b, MultinodeEkvOwner, :start_ekv_member_and_wait, [
          Keyword.put(base, :data_dir, dir_b),
          me
        ])

        await_started(node_a)
        await_started(node_b)

        task_id = "journal-crossnode-#{System.unique_integer([:positive])}"

        for n <- 1..3 do
          assert :ok =
                   :erpc.call(
                     node_a,
                     EventJournalEkv,
                     :append,
                     [ekv_name, task_id, 1, %{n: n}],
                     15_000
                   )
        end

        # Replay reads the local replica (eventual): bounded wait for replication.
        assert eventually(fn ->
                 :erpc.call(node_b, EventJournalEkv, :replay_after, [ekv_name, task_id, 0], 5_000) ==
                   {:ok, [%{n: 1}, %{n: 2}, %{n: 3}]}
               end),
               "events appended on node A must replay on node B"
      after
        stop_if_alive(peer_a)
        stop_if_alive(peer_b)
      end
    end
  end

  defp start_real_peer(host, cookie, code_paths) do
    peer_name = :"ash_a2a_ejournal_peer_#{System.unique_integer([:positive, :monotonic])}"

    {:ok, peer_pid, peer_node} =
      :peer.start_link(%{name: peer_name, host: host, args: [~c"-setcookie", Atom.to_charlist(cookie)]})

    assert :ok = :rpc.call(peer_node, :code, :add_pathsz, [code_paths])
    {peer_pid, peer_node}
  end

  # `:peer.stop/1` must run in the process that called `start_link` (try/after, not on_exit).
  defp stop_if_alive(peer_pid) do
    if Process.alive?(peer_pid), do: :peer.stop(peer_pid)
    :ok
  end

  defp await_started(peer_node) do
    receive do
      {:ekv_member_started, ^peer_node, sup_pid} -> sup_pid
      {:ekv_member_start_failed, ^peer_node, reason} -> flunk("EKV member failed: #{inspect(reason)}")
    after
      30_000 -> flunk("EKV member on #{inspect(peer_node)} not ready within 30s")
    end
  end

  defp eventually(fun, attempts \\ 100, sleep_ms \\ 50)
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
