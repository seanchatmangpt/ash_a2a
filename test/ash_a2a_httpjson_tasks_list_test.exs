# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.HTTPJSONTasksListTest.Resource do
  @moduledoc """
  Real fixture resource, private to this test file: a single real `:read`
  skill on a real ETS-backed Ash resource, so dispatch has exactly one skill
  and needs no `:skill` metadata.
  """

  use Ash.Resource,
    domain: AshA2A.HTTPJSONTasksListTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])
  end

  a2a do
    skill(:echo, :read)
  end
end

defmodule AshA2A.HTTPJSONTasksListTest.Domain do
  @moduledoc "Real fixture domain for the resource above."

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.HTTPJSONTasksListTest.Resource)
  end
end

defmodule AshA2A.HTTPJSONTasksListTest.EchoAgent do
  @moduledoc "Real `AshA2A.Agent` GenServer over the fixture resource above."

  use AshA2A.Agent,
    resource_or_domain: AshA2A.HTTPJSONTasksListTest.Resource,
    name: "httpjson_tasks_list_echo_agent"
end

defmodule AshA2A.HTTPJSONTasksListTest.Stack do
  @moduledoc """
  Real two-plug stack: `AshA2A.Protocol.Plug.Auth` (bearer) in front of the
  `AshA2A.Transport.HTTPJSON` binding, so requests carry a verified principal
  into `conn.private[:a2a][:auth]` exactly as in production.
  """

  @behaviour Plug

  @impl Plug
  def init({auth_opts, binding_opts}) do
    {AshA2A.Protocol.Plug.Auth.init(auth_opts), AshA2A.Transport.HTTPJSON.init(binding_opts)}
  end

  @impl Plug
  def call(conn, {auth_opts, binding_opts}) do
    conn = AshA2A.Protocol.Plug.Auth.call(conn, auth_opts)

    if conn.halted, do: conn, else: AshA2A.Transport.HTTPJSON.call(conn, binding_opts)
  end
end

defmodule AshA2A.HTTPJSONTasksListTest do
  @moduledoc """
  Court for `GET /tasks` (§5.3 tasks/list) on the A2A v1.0 HTTP+JSON/REST
  transport binding (`AshA2A.Transport.HTTPJSON`).

  A real Bandit server on a loopback ephemeral port, a real supervised
  `use AshA2A.Agent` GenServer over a real ETS Ash resource, the real
  `AshA2A.Protocol.Plug.Auth` bearer middleware in front of the binding, and
  real `Req` HTTP calls: two authenticated principals (alice, bob), owner
  scoping (SEC-01), a real pagination cycle over more tasks than one page
  holds, the real `AshA2A.Protocol.Task.Filter` status filter, and the
  JSON-RPC `Request.validate_params/1` rejection surface for invalid query
  parameters. No mocks.
  """

  use ExUnit.Case, async: false

  @moduletag :serial_shard

  alias AshA2A.Test.{AgentSupervisorCase, EphemeralHttp}

  @error_info "type.googleapis.com/google.rpc.ErrorInfo"

  @tokens %{"alice-token" => %{sub: "alice"}, "bob-token" => %{sub: "bob"}}

  setup do
    agent = AshA2A.HTTPJSONTasksListTest.EchoAgent

    {_sup, _registry} =
      AgentSupervisorCase.start_supervised_agents!(__MODULE__, [agent])

    auth_opts = [
      schemes: %{"bearer_auth" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}},
      verify: fn _scheme, token, _conn -> Map.fetch(@tokens, token) end
    ]

    binding_opts =
      AshA2A.Transport.HTTPJSON.init(agent: agent, base_url: "http://127.0.0.1/fixture")

    %{server: EphemeralHttp.start!({AshA2A.HTTPJSONTasksListTest.Stack, {auth_opts, binding_opts}})}
  end

  # -- helpers ----------------------------------------------------------------

  defp message_map(text) do
    AshA2A.Protocol.JSON.encode!(AshA2A.Protocol.Message.new_user(text))
  end

  defp send_as!(server, token, text) do
    resp =
      Req.post!(url: server.base_url <> "/message:send",
        headers: [{"authorization", "Bearer " <> token}],
        json: %{"message" => message_map(text)}
      )

    assert resp.status == 200
    assert %{"task" => %{"id" => task_id}} = resp.body
    task_id
  end

  defp list(server, token, query \\ "") do
    Req.get!(url: server.base_url <> "/tasks" <> query,
      headers: [{"authorization", "Bearer " <> token}]
    )
  end

  # -- owner scoping (SEC-01) ---------------------------------------------------

  test "alice's list shows only alice's tasks; bob's only bob's", %{server: server} do
    alice_tasks = [send_as!(server, "alice-token", "a1"), send_as!(server, "alice-token", "a2")]
    bob_task = send_as!(server, "bob-token", "b1")

    resp = list(server, "alice-token")

    assert resp.status == 200
    assert %{"tasks" => tasks, "totalSize" => 2, "pageSize" => 2} = resp.body
    assert MapSet.new(tasks, & &1["id"]) == MapSet.new(alice_tasks)
    refute bob_task in Enum.map(tasks, & &1["id"])

    assert %{"tasks" => bob_tasks, "totalSize" => 1} = list(server, "bob-token").body
    assert Enum.map(bob_tasks, & &1["id"]) == [bob_task]
  end

  test "wire tasks carry no owner key or verified auth metadata", %{server: server} do
    send_as!(server, "alice-token", "a1")

    assert %{"tasks" => [task]} = list(server, "alice-token").body

    metadata = task["metadata"] || %{}
    refute Map.has_key?(metadata, "ash_a2a.owner")
    refute Map.has_key?(metadata, "a2a.auth")
  end

  # -- pagination ----------------------------------------------------------------

  test "pagination cycle: N > pageSize tasks page through with nextPageToken", %{server: server} do
    created = for i <- 1..5, do: send_as!(server, "alice-token", "task #{i}")

    page1 = list(server, "alice-token", "?pageSize=2")
    assert %{"tasks" => p1, "totalSize" => 5, "pageSize" => 2, "nextPageToken" => token1} =
             page1.body

    assert length(p1) == 2
    assert is_binary(token1) and token1 != ""

    assert %{"tasks" => p2, "totalSize" => 5, "nextPageToken" => token2} =
             list(server, "alice-token", "?pageSize=2&pageToken=#{token1}").body

    assert length(p2) == 2

    assert %{"tasks" => p3, "totalSize" => 5, "nextPageToken" => ""} =
             list(server, "alice-token", "?pageSize=2&pageToken=#{token2}").body

    assert length(p3) == 1

    paged_ids = Enum.map(p1 ++ p2 ++ p3, & &1["id"])
    assert MapSet.new(paged_ids) == MapSet.new(created)
    assert length(paged_ids) == length(Enum.uniq(paged_ids))
  end

  test "an unknown pageToken is 400 INVALID_PARAMS", %{server: server} do
    send_as!(server, "alice-token", "a1")

    resp = list(server, "alice-token", "?pageSize=2&pageToken=tsk-unknown")

    assert resp.status == 400
    assert %{"error" => %{"code" => 400, "details" => [%{"@type" => @error_info, "reason" => "INVALID_PARAMS"}]}} =
             resp.body
  end

  # -- status filter ---------------------------------------------------------------

  test "status filter selects the matching state only", %{server: server} do
    send_as!(server, "alice-token", "a1")
    send_as!(server, "alice-token", "a2")

    assert %{"tasks" => tasks, "totalSize" => 2} =
             list(server, "alice-token", "?status=TASK_STATE_COMPLETED").body

    assert length(tasks) == 2
    assert Enum.all?(tasks, &(&1["status"]["state"] == "TASK_STATE_COMPLETED"))

    # A valid state that no task is in: real Filter.apply semantics, empty page.
    assert %{"tasks" => [], "totalSize" => 0, "nextPageToken" => ""} =
             list(server, "alice-token", "?status=TASK_STATE_FAILED").body
  end

  # -- param validation (same Request.validate_params/1 surface as JSON-RPC) -------

  test "invalid pageSize is 400 INVALID_PARAMS", %{server: server} do
    for query <- ["?pageSize=0", "?pageSize=101", "?pageSize=abc"] do
      resp = list(server, "alice-token", query)

      assert resp.status == 400, query
      assert %{"error" => %{"code" => 400, "details" => [%{"@type" => @error_info, "reason" => "INVALID_PARAMS"}]}} =
               resp.body
    end
  end

  test "invalid status value is 400 INVALID_PARAMS", %{server: server} do
    resp = list(server, "alice-token", "?status=TASK_STATE_BOGUS")

    assert resp.status == 400
    assert %{"error" => %{"code" => 400, "details" => [%{"@type" => @error_info, "reason" => "INVALID_PARAMS"}]}} =
             resp.body
  end

  test "historyLength truncates listed task history and rejects junk", %{server: server} do
    send_as!(server, "alice-token", "a1")

    assert %{"tasks" => [task]} = list(server, "alice-token", "?historyLength=1").body
    assert length(task["history"]) <= 1

    resp = list(server, "alice-token", "?historyLength=bogus")
    assert resp.status == 400
    assert %{"error" => %{"code" => 400}} = resp.body
  end

  test "empty listing for a principal with no tasks still validates", %{server: server} do
    resp = list(server, "bob-token")

    assert resp.status == 200
    assert %{"tasks" => [], "totalSize" => 0, "pageSize" => 0, "nextPageToken" => ""} = resp.body
  end
end
