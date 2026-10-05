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

  defp respond(conn, {status, payload}) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(payload))
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

  alias AshA2A.AuthZEN.{Absorption, Client, DecisionPool, Metadata, Types}
  alias AshA2A.C2.{AuthorityRequest, Certificate, PreparedEffect}
  alias AshA2A.Enterprise.AuthZENClientCourt.PDP
  alias AshA2A.SPIFFE.{AttestedIdentity, PDPBinding}
  alias AshA2A.Test.EphemeralHttp

  @pdp "https://court-pdp.example"

  setup do
    table =
      :ets.new(
        :"authzen_client_court_#{System.unique_integer()}",
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
      if :ets.info(table) != :undefined do
        :ets.delete(table)
      end
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

  defp wait_down(port, attempts \\ 50)

  defp wait_down(_port, 0), do: flunk("PDP port never closed")

  defp wait_down(port, attempts) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [], 100) do
      {:error, _} ->
        :ok

      {:ok, socket} ->
        :gen_tcp.close(socket)
        Process.sleep(50)
        wait_down(port, attempts - 1)
    end
  end

  @spiffe_id "spiffe://prod.example/pdp/authzen"

  defp binding! do
    %PDPBinding{policy_decision_point: @pdp, spiffe_id: @spiffe_id, trust_domain: "prod.example"}
  end

  defp attested! do
    {:ok, attested} =
      AttestedIdentity.from_verified(@spiffe_id,
        svid_type: :x509,
        bundle_digest: "sha256:bundle",
        observed_at: 1
      )

    attested
  end

  defp authority_ctx do
    %{
      policy_epoch: 1,
      revocation_epoch: 2,
      generation: 3,
      audience: "actuator:payments",
      local_certificate_issuer: __MODULE__.LocalIssuer
    }
  end

  # V4-21 defect-handoff proof: the REAL `Client.new/2` default transport (no
  # shim) carries `Absorption.authorize/5` end-to-end over the real PDP.
  test "absorption: the real default transport admits end-to-end through Absorption.authorize/5",
       %{
         client: client,
         table: table
       } do
    effect = PreparedEffect.new("principal:alice", :payments, %{"id" => 42}, %{"amount" => 100})
    ctx = authority_ctx()
    request = AuthorityRequest.new(effect, ctx)

    allow(table, "principal:alice", "payments", effect.digest, true)

    assert {:ok, response, receipt} =
             Absorption.authorize(request, client, attested!(), binding!(), ctx)

    assert %Certificate{} = response.certificate
    assert response.certificate.effect_digest == effect.digest

    assert %{
             "subject" => %{"type" => "sa2a-principal", "id" => "principal:alice"},
             "action" => %{"name" => "payments"},
             "resource" => %{"type" => "sa2a-prepared-effect", "id" => resource_id}
           } = :ets.lookup_element(table, :last_request, 2)

    assert resource_id == effect.digest

    assert receipt.authority == :none
    assert receipt.consequence == :evidence_only
  end

  test "absorption: PDP down fail-closes through the real default transport", %{client: client} do
    effect = PreparedEffect.new("principal:alice", :payments, %{"id" => 42}, %{})
    ctx = authority_ctx()
    request = AuthorityRequest.new(effect, ctx)

    {:ok, latch} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, active: false, backlog: 1)
    {:ok, dead_port} = :inet.port(latch)

    dead_client =
      Client.new(
        %{
          client.metadata
          | access_evaluation_endpoint: "http://127.0.0.1:#{dead_port}/access/v1/evaluation"
        },
        timeout: 150
      )

    assert {:error, :pdp_unreachable} =
             Absorption.authorize(request, dead_client, attested!(), binding!(), ctx)

    :gen_tcp.close(latch)
  end

  defmodule LocalIssuer do
    @moduledoc """
    Real hand-written certificate issuer (same pattern as
    `AshA2A.SPIFFE.PDPBindingTest.LocalIssuer`): a real interface
    implementation, not a mock.
    """

    def issue(request, _ctx) do
      {:ok,
       %Certificate{
         version: 1,
         effect_digest: request.effect_digest,
         principal: request.principal,
         policy_epoch: request.policy_epoch,
         revocation_epoch: request.revocation_epoch,
         generation: request.generation,
         nonce: "0123456789abcdef",
         not_before_ms: 0,
         expires_at_ms: 10_000,
         audience: request.audience,
         threshold: 1,
         signatures: []
       }}
    end
  end

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

  test "fail-closed: PDP down is a typed refusal", %{
    client: client,
    table: table,
    port: port,
    server_pid: server_pid
  } do
    allow(table, "frank", "read", "doc-6", true)
    assert {decision, 1} = eval(client, table, "frank", "read", "doc-6")
    assert {:ok, %Types.Decision{decision: true}} = decision

    true = Process.unlink(server_pid)
    Process.exit(server_pid, :shutdown)
    wait_down(port)

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
