# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SecurityWave3JournalTest do
  @moduledoc """
  Security wave 3, durable event journal:

    * a journal replay (`tasks/resubscribe` with `lastSeenGeneration`) applies
      the same owner check as `tasks/get`: a foreign principal is told the task
      does not exist and receives none of its events
    * trimming drops a generation's sequence counter with its last event, so
      the ETS table does not grow by one row per generation forever
    * the legacy push sender connects to the address it admitted
  """

  use ExUnit.Case, async: false

  alias AshA2A.Sim.MCP.Tools
  alias AshA2A.Sim.Server
  alias AshA2A.TaskStore.EventJournalEts

  @moduletag capture_log: true
  @moduletag timeout: 120_000

  setup_all do
    {:ok, server} = Server.start_link()
    on_exit(fn -> if Process.alive?(server), do: Server.stop(server) end)
    {:ok, info: Server.info()}
  end

  defp rpc(info, token, method, params) do
    {:ok, answer} =
      Tools.call(
        "a2a_raw_request",
        %{
          "binding" => "jsonrpc",
          "mount" => "jsonrpc",
          "token" => token,
          "json" => %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}
        },
        %{info: info}
      )

    answer
  end

  defp new_task(info) do
    {:ok, sent} =
      Tools.call(
        "a2a_send_message",
        %{"binding" => "jsonrpc", "skill" => "count_notes", "token" => "writer"},
        %{info: info}
      )

    get_in(sent, ["json", "result", "task", "id"]) || get_in(sent, ["json", "result", "id"]) ||
      flunk("no task id in #{inspect(sent["json"])}")
  end

  test "journal replay for a foreign principal is task-not-found, like tasks/get", %{info: info} do
    id = new_task(info)

    # Positive control: the owner reads the task and resumes from generation 0.
    assert get_in(rpc(info, "writer", "tasks/get", %{"id" => id}), ["json", "result"])

    for method <- ["tasks/get", "tasks/resubscribe"] do
      answer =
        rpc(info, "sim-agent-intruder", method, %{"id" => id, "lastSeenGeneration" => 0})

      assert get_in(answer, ["json", "error", "code"]) == -32_001,
             "#{method}: #{inspect(answer["json"] || answer["body"])}"

      assert answer["frames"] in [[], nil]
      refute inspect(answer) =~ "count_notes"
    end
  end

  test "trim removes the counter of a generation whose events are all gone" do
    name = :"wave3_journal_#{System.unique_integer([:positive])}"
    start_supervised!({EventJournalEts, name: name})

    for gen <- 1..50, do: :ok = EventJournalEts.append(name, "t-1", gen, %{"g" => gen})
    assert :ok = EventJournalEts.trim(name, "t-1", 5)

    rows = :ets.tab2list(name)
    events = for {{"t-1", _, _}, _} <- rows, do: :ok
    counters = for {{:counter, "t-1", _}, _} <- rows, do: :ok

    assert length(events) == 5
    assert length(counters) == 5
    assert {:ok, kept} = EventJournalEts.replay_after(name, "t-1", 0)
    assert Enum.map(kept, & &1["g"]) == Enum.to_list(46..50)
  end

  test "the legacy push sender connects to the address it admitted (no re-resolution)" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    parent = self()

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen, 5_000)
      {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
      send(parent, {:request, data})
      :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 0\r\nconnection: close\r\n\r\n")
      :gen_tcp.close(socket)
    end)

    # "pinned.example" does not exist in DNS: a delivery that resolved the name
    # a second time could not reach the listener. The admitted address is used.
    config = %{url: "http://pinned.example:#{port}/hook", token: nil, authentication: nil}

    assert :ok =
             AshA2A.Protocol.PushNotificationSender.HTTP.deliver(config, %{"a" => 1},
               require_https: false,
               allow_cidrs: ["127.0.0.0/8"],
               resolver: fn
                 _host, :inet -> {:ok, [{127, 0, 0, 1}]}
                 _host, _family -> {:error, :nxdomain}
               end,
               attempts: 1
             )

    assert_receive {:request, data}, 5_000
    assert data =~ "POST /hook"
    assert String.downcase(data) =~ "host: pinned.example:#{port}"
  end
end
