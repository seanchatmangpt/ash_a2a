# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.WoCheckinSimWorkerTest do
  @moduledoc """
  V8-SIM-WORKER lane: ONE simulated worker agent proven end-to-end over the
  real `AshA2A.Protocol.Plug` on a real ephemeral Bandit port (127.0.0.1,
  port 0) with zero mocks:

  1. the served card advertises exactly one skill `wo.check_in`;
  2. `message/send` drives the srve woVisits machine law in memory
     (ported read-only, cite header in
     `test/support/wo_checkin_sim_fixture.ex`); the task completes with the
     machine's terminal state as the response artifact;
  3. the geofence refusal arm parks the visit; the fail-closed override arm
     refuses an empty justification and stays parked;
  4. `tasks/get` round-trips the completed task.

  pplan restart-resumption is registered as the follow-up (receipt cites the
  existing durable court ash_a2a `test/ash_a2a_pplan_durability_test.exs`
  and the provider seam `lib/ash_a2a/providers/pplan.ex`).
  """

  use ExUnit.Case, async: false

  alias AshA2A.Protocol.JSON
  alias AshA2A.Protocol.Message
  alias AshA2A.Protocol.Part
  alias AshA2A.Test.EphemeralHttp
  alias AshA2A.Test.WoCheckinSim.MachineLaw
  alias AshA2A.Test.WoCheckinSim.WorkerAgent

  setup do
    MachineLaw.reset()

    name = :"wo_checkin_sim_agent_#{System.unique_integer([:positive])}"

    {:ok, pid} = WorkerAgent.start_link(name: name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    server =
      EphemeralHttp.start!({AshA2A.Protocol.Plug, agent: name, base_url: "http://127.0.0.1:4000/a2a"})

    %{server: server, agent_pid: pid}
  end

  defp rpc(server, method, params) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => method,
        "params" => params
      })

    {:ok, resp} =
      Req.post(server.base_url <> "/",
        body: body,
        headers: [{"content-type", "application/json"}]
      )

    resp
  end

  defp send_check_in(server, args) do
    base = Message.new_user([Part.Data.new(args)])
    message = %{base | metadata: %{"skill" => "wo.check_in"}}

    {:ok, encoded_message} = JSON.encode(message)

    rpc(server, "message/send", %{"message" => encoded_message})
  end

  defp data_payload(server, task_id) do
    {:ok, resp} =
      Req.post(server.base_url <> "/",
        body:
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => System.unique_integer([:positive]),
            "method" => "tasks/get",
            "params" => %{"id" => task_id}
          }),
        headers: [{"content-type", "application/json"}]
      )

    body = resp.body

    body["result"]["artifacts"]
    |> List.wrap()
    |> Enum.flat_map(fn a -> a["parts"] || [] end)
    |> Enum.find_value(fn p -> Map.get(p, "data") end)
  end

  test "served card advertises exactly one skill wo.check_in over real HTTP", %{
    server: server
  } do
    {:ok, resp} = Req.get(server.base_url <> "/.well-known/agent-card.json")
    assert resp.status == 200

    card = resp.body

    assert [skill] = card["skills"]

    assert skill["name"] == "wo.check_in"
    # the skill's id carries the real resource/action path it dispatches
    assert skill["id"] == "AshA2A.Test.WoCheckinSim.WoVisit.wo_check_in"

    assert is_binary(skill["description"])
    assert is_list(skill["tags"])
  end

  test "message/send completes with the machine terminal state as artifact", %{
    server: server
  } do
    resp = send_check_in(server, %{"workOrderId" => "wo-sim-1", "visitId" => "visit-sim-1"})
    assert resp.status == 200

    assert %{"result" => %{"task" => %{"id" => id}}} = resp.body

    payload = data_payload(server, id)

    assert payload["terminal"] == true
    assert payload["state"] == "visit_detail_ready"
    assert payload["attendanceRecorded"] == true
    assert payload["visited"] == ["visit_detail_ready", "check_in", "visit_detail_ready"]
  end

  test "geofence refusal parks; empty-justification override stays parked; justified override completes", %{
    server: server
  } do
    resp =
      send_check_in(server, %{
        "workOrderId" => "wo-sim-2",
        "visitId" => "visit-sim-2",
        "geofenceRefused" => true,
        "distanceMeters" => 250
      })

    assert resp.status == 200
    assert %{"result" => %{"task" => %{"id" => id1}}} = resp.body

    payload1 = data_payload(server, id1)
    assert payload1["state"] == "parked_override"
    assert payload1["geofenceRefusal"]["distance"] == 250

    resp2 =
      send_check_in(server, %{
        "workOrderId" => "wo-sim-2",
        "visitId" => "visit-sim-2",
        "overrideJustification" => ""
      })

    assert resp2.status == 200
    assert %{"result" => %{"task" => %{"id" => id2}}} = resp2.body

    payload2 = data_payload(server, id2)
    assert payload2["state"] == "parked_override"
    assert payload2["refusal"] =~ "fail-closed"

    resp3 =
      send_check_in(server, %{
        "workOrderId" => "wo-sim-2",
        "visitId" => "visit-sim-2",
        "overrideJustification" => "dispatcher override: site gate inaccessible"
      })

    assert resp3.status == 200
    assert %{"result" => %{"task" => %{"id" => id3}}} = resp3.body

    payload3 = data_payload(server, id3)
    assert payload3["state"] == "visit_detail_ready"
    assert payload3["terminal"] == true
    assert payload3["attendanceRecorded"] == true
    assert payload3["overrideJustification"] == "dispatcher override: site gate inaccessible"
  end

  test "tasks/get round-trips the completed task", %{server: server} do
    resp = send_check_in(server, %{"workOrderId" => "wo-sim-3", "visitId" => "visit-sim-3"})
    assert resp.status == 200

    assert %{"result" => %{"task" => %{"id" => id}}} = resp.body

    get_resp = rpc(server, "tasks/get", %{"id" => id})
    assert get_resp.status == 200

    assert %{"result" => %{"id" => ^id}} = get_resp.body
    assert get_resp.body["result"]["status"]["state"] == "TASK_STATE_COMPLETED"
  end
end
