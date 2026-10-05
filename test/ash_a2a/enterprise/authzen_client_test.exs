# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Enterprise.AuthZENClientCourt.PDP do
  @moduledoc """
  Real Bandit-served PDP implementing the OpenID AuthZEN evaluation contract:
  parses a real JSON evaluation request, consults a real policy table, and answers
  the AuthZEN decision payload. Every HTTP request increments a real ETS counter,
  so a cache hit is witnessed by absent HTTP traffic, not by a mock. Resource ids
  `"boom"` and `"garbage"` are adversarial fixtures: a 500 answer and a 200 answer
  with an undecodable payload.
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    table = opts.table

    case Jason.decode(body) do
      {:ok, %{"subject" => subject, "action" => action, "resource" => resource} = req} ->
        :ets.update_counter(table, :request_count, {2, 1}, {:request_count, 0})
        :ets.insert(table, {:last_request, req})
        respond(conn, decision_for(table, subject, action, resource))

      _ ->
        respond(conn, {400, %{"error" => "invalid_request"}})
    end
  end

  defp decision_for(table, subject, action, resource) do
    case resource["id"] do
      "boom" ->
        {500, %{"error" => "internal"}}

      "garbage" ->
        {200, %{"status" => "ok", "no" => "decision"}}

      id ->
        allowed =
          try do
            :ets.lookup_element(
              table,
              {:allow, subject["id"], action["name"], id},
              2
            )
          rescue
            ArgumentError -> false
          end

        {200, %{decision: allowed, context: %{}}}
    end
  end
end

defmodule AshA2A.Enterprise.AuthZENClientCourt do
  @moduledoc """
  FR-01.3 court for `AshA2A.AuthZEN.Client.evaluate/4`: a real PDP served by
  Bandit over real loopback HTTP, real JSON, zero mocks. Kills: (1) permit and
  deny round-trips, (2) fail-closed typed refusals (PDP down, non-2xx,
  undecodable payload), (3) cache hits witnessed by a frozen HTTP request
  counter, (4) TTL expiry re-consulting the PDP, (5) the exact AuthZEN wire
  shape the PDP receives.
  """

  use ExUnit.Case, async: false

  alias AshA2A.AuthZEN.{Client, DecisionPool, Metadata, Types}
  alias AshA2A.Enterprise.AuthZENClientCourt.PDP
  alias AshA2A.Test.EphemeralHttp

  @pdp "https://court-pdp.example"

  setup do
    {:ok, table} =
      :ets.new(:"authzen_client_court_#{System.unique_integer()}",
        [:set, :public, read_concurrency: true]
      )

    :ets.insert(table, {:request_count, 0})
    :ok = DecisionPool.ensure_started([])
    :ok = DecisionPool.cache_clear()

    %{port: port, base_url: base_url, pid: server_pid} =
      EphemeralHttp.start!({PDP, %{table: table}})

    metadata = %Metadata{
      policy_decision_point: @pdp,
      access_evaluation_endpoint: base_url <> "/access/v1/evaluation"
    }

    client = Client.new(metadata, timeout: 2_000)

    on_exit(fn ->
      :ets.delete(table)
    end)

    %{table: table, client: client, port: port, server_pid: server_pid}
  end

  defp eval(client, table, subject_id, action_name, resource_id, opts \\ []) do
    decision =
      Client.evaluate(
        client,
        %Types.Entity{type: "user", id: subject_id},
        %Types.Action{name: action_name},
        %Types.Entity{type: "document", id: resource_id},
        %{"tier" => "court"},
        opts
      )

    {decision, request_count(table)}
  end

  defp request_count(table), do: :ets.lookup_element(table, :request_count, 2)

  defp allow(table, s, a, r, value), do: :ets.insert(table, {{:allow, s, a, r}, value})

  test "permits: an allow decision round-trips as observed evidence", %{
    client: client,
    table: table
  } do
    allow(table, "alice", "read", "doc-1", true)

    assert {:ok, %Types.Decision{decision: true, source: @pdp}} =
             eval(client, table, "alice", "read", "doc-1") |> elem(0)
  end

  test "denies: a false decision is observed evidence, not a refusal", %{
    client: client,
    table: table
  } do
    allow(table, "bob", "write", "doc-2", false)

    assert {:ok, %Types.Decision{decision: false, source: @pdp}} =
             eval(client, table, "bob", "write", "doc-2") |> elem(0)
  end

  test "wire shape: the PDP receives subject/action/resource/context", %{
    client: client,
    table: table
  } do
    allow(table, "carol", "read", "doc-3", true)
    {_decision, count} = eval(client, table, "carol", "read", "doc-3")
    assert count == 1

    assert %{
             "subject" => %{"type" => "user", "id" => "carol"},
             "action" => %{"name" => "read"},
             "resource" => %{"type" => "document", "id" => "doc-3"},
             "context" => %{"tier" => "court"}
           } = :ets.lookup_element(table, :last_request, 2)
  end

  test "cache hit: a second identical evaluation makes zero HTTP calls", %{
    client: client,
    table: table
  } do
    allow(table, "dave", "read", "doc-4", true)

    {decision1, count1} = eval(client, table, "dave", "read", "doc-4")
    assert {:ok, %Types.Decision{decision: true}} = decision1
    assert count1 == 1

    {decision2, count2} = eval(client, table, "dave", "read", "doc-4")
    assert {:ok, %Types.Decision{decision: true}} = decision2
    assert count2 == 1

    {_decision3, count3} = eval(client, table, "dave", "read", "doc-9")
    assert count3 == 2
  end

  test "TTL expiry re-consults the PDP", %{client: client, table: table} do
    allow(table, "erin", "read", "doc-5", true)

    assert {_decision, count1} = eval(client, table, "erin", "read", "doc-5", cache_ttl: 30)
    assert count1 == 1

    {decision, _} = eval(client, table, "erin", "read", "doc-5", cache_ttl: 30)
    assert {:ok, %Types.Decision{decision: true}} = decision
    assert request_count(table) == 1

    Process.sleep(60)

    assert {:ok, %Types.Decision{decision: true}} =
             eval(client, table, "erin", "read", "doc-5") |> elem(0)

    assert request_count(table) == 2
  end

  test "fail-closed: PDP down is a typed refusal", %{client: client, table: table, server_pid: server_pid} do
    allow(table, "frank", "read", "doc-6", true)
    assert {decision, 1} = eval(client, table, "frank", "read", "doc-6")
    assert {:ok, %Types.Decision{decision: true}} = decision

    true = Process.unlink(server_pid)
    Process.exit(server_pid, :shutdown)

    assert {:error, :pdp_unreachable} =
             eval(client, table, "frank", "read", "doc-9") |> elem(0)
  end

  test "fail-closed: a non-2xx PDP answer is a typed refusal", %{client: client, table: table} do
    assert {:error, {:pdp_error, 500}} =
             eval(client, table, "grace", "read", "boom") |> elem(0)
  end

  test "fail-closed: an undecodable payload is a typed refusal and is not cached", %{
    client: client,
    table: table
  } do
    assert {:error, :invalid_decision} =
             eval(client, table, "heidi", "read", "garbage") |> elem(0)

    assert {:error, :invalid_decision} =
             eval(client, table, "heidi", "read", "garbage") |> elem(0)

    assert request_count(table) == 2
  end

  test "fail-closed: non-AuthZEN argument shapes are refused", %{client: client} do
    assert {:error, :invalid_subject} =
             Client.evaluate(
               client,
               "alice",
               %Types.Action{name: "read"},
               %Types.Entity{type: "document", id: "doc-7"}
             )
  end
end
