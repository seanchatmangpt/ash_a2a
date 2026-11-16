# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.EventJournalCrossnodeTest do
  @moduledoc """
  Journal-backed resubscribe across two real `:peer` nodes sharing a real
  two-member `EKV` cluster (task store and `AshA2A.TaskStore.EventJournalEkv`),
  same peer pattern as `AshA2A.EventJournalEkvTest`. A real agent on node A
  runs the task; a second real agent on node B, which never saw it, serves
  `tasks/resubscribe` with `lastSeenGeneration` and replays the missed events
  in order over a real `Plug.Test` SSE conn. No mocks.
  """
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_solo

  alias AshA2A.Test.EventJournalFixture, as: Fixture
  alias AshA2A.Test.EventJournalFixture.Agent

  setup do
    System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)
    already_alive? = Node.alive?()

    unless already_alive? do
      {:ok, _pid} = Node.start(:"ash_a2a_ejournal_x_primary_#{System.pid()}", :shortnames)
    end

    on_exit(fn -> if not already_alive? and Node.alive?(), do: Node.stop() end)
    :ok
  end

  test "events journaled by the agent on node A replay through the agent on node B" do
    host =
      Node.self() |> Atom.to_string() |> String.split("@") |> List.last() |> String.to_charlist()

    cookie = Node.get_cookie()
    code_paths = :code.get_path()

    {peer_a, node_a} = start_real_peer(host, cookie, code_paths)
    {peer_b, node_b} = start_real_peer(host, cookie, code_paths)

    try do
      assert :erpc.call(node_a, Node, :ping, [node_b], 10_000) == :pong

      uniq = System.unique_integer([:positive, :monotonic])
      ekv_name = :"ash_a2a_ejournal_x_#{uniq}"
      dir_a = Path.join(System.tmp_dir!(), "ash_a2a_ejournal_x_a_#{uniq}")
      dir_b = Path.join(System.tmp_dir!(), "ash_a2a_ejournal_x_b_#{uniq}")
      on_exit(fn -> File.rm_rf!(dir_a) end)
      on_exit(fn -> File.rm_rf!(dir_b) end)

      base = [name: ekv_name, cluster_size: 2, wait_for_quorum: :timer.seconds(25)]
      me = self()

      # Concurrent start: each member's quorum wait blocks until the other joins.
      Node.spawn(node_a, Fixture, :start_node_and_wait, [Keyword.put(base, :data_dir, dir_a), me])
      Node.spawn(node_b, Fixture, :start_node_and_wait, [Keyword.put(base, :data_dir, dir_b), me])
      await_started(node_a)
      await_started(node_b)

      # The whole task runs on node A; node B's agent never handles it.
      {task_id, [g1, g2, g3]} =
        :erpc.call(node_a, Fixture, :drive, [Agent, ["still thinking", "done"]], 30_000)

      expected_tail = [{:status, g3, "TASK_STATE_COMPLETED"}]

      # Replay reads node B's local replica (eventual): bounded wait.
      assert eventually(fn ->
               case :erpc.call(node_b, Fixture, :resubscribe, [Agent, task_id, g1], 15_000) do
                 frames when is_list(frames) ->
                   frames |> Enum.map(&Fixture.summary/1) |> Enum.take(-1) == expected_tail

                 _ ->
                   false
               end
             end),
             "node B must replay node A's events up to the terminal status"

      frames = :erpc.call(node_b, Fixture, :resubscribe, [Agent, task_id, g1], 15_000)
      summaries = Enum.map(frames, &Fixture.summary/1)
      gens = Enum.map(summaries, &elem(&1, 1))

      refute Enum.any?(summaries, &match?({:task, _, _}, &1))
      assert gens == Enum.sort(gens)
      assert Enum.all?(gens, &(&1 > g1))
      assert {:status, g2, "TASK_STATE_INPUT_REQUIRED"} in summaries
      assert List.last(summaries) == {:status, g3, "TASK_STATE_COMPLETED"}

      texts =
        for %{"messageUpdate" => %{"message" => %{"parts" => [%{"text" => text}]}}} <- frames,
            do: text

      assert texts == ["still thinking", "done"]
    after
      stop_if_alive(peer_a)
      stop_if_alive(peer_b)
    end
  end

  defp start_real_peer(host, cookie, code_paths) do
    peer_name = :"ash_a2a_ejournal_x_peer_#{System.unique_integer([:positive, :monotonic])}"

    {:ok, peer_pid, peer_node} =
      :peer.start_link(%{
        name: peer_name,
        host: host,
        args: [~c"-setcookie", Atom.to_charlist(cookie)]
      })

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
      {:journal_node_started, ^peer_node} -> :ok
      {:journal_node_failed, ^peer_node, reason} -> flunk("EKV member failed: #{inspect(reason)}")
    after
      40_000 -> flunk("node #{inspect(peer_node)} not ready within 40s")
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
