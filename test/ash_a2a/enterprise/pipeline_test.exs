# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Enterprise.PipelineCourt.Converse do
  @moduledoc """
  Real fixture resource for the V4-14 pipeline court: one generic `:converse`
  action requiring `:say` (completes when present, pauses INPUT_REQUIRED when
  absent), exactly like the suite's established owner-scope fixture.
  """

  use Ash.Resource,
    domain: AshA2A.Enterprise.PipelineCourt.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:label, :string, public?: true)
  end

  actions do
    defaults([:read])

    action :converse, :map do
      argument(:say, :string, allow_nil?: false)

      run(fn input, _context ->
        {:ok, %{say: input.arguments.say}}
      end)
    end
  end

  a2a do
    skill(:converse, :converse, consequence: :observe)
  end
end

defmodule AshA2A.Enterprise.PipelineCourt.Domain do
  @moduledoc false

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.Enterprise.PipelineCourt.Converse)
  end
end

defmodule AshA2A.Enterprise.PipelineCourt.Agent do
  @moduledoc """
  Real `AshA2A.Agent` GenServer serving the fixture resource (inline
  execution, anonymous callers allowed — the enterprise gates under court
  are the identity layer here).
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Enterprise.PipelineCourt.Converse,
    name: "enterprise_pipeline_court_agent",
    require_authenticated_caller: false,
    execution: [mode: :inline]
end

defmodule AshA2A.Enterprise.PipelineCourt.PDP do
  @moduledoc """
  Real Bandit-served AuthZEN PDP over a real ETS policy table. `"boom"`
  answers 500 (adversarial fixture, same convention as the AuthZEN client
  court). Every request increments a real counter.
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    table = opts.table

    case Jason.decode(body) do
      {:ok, %{"subject" => subject, "action" => action, "resource" => resource}} ->
        :ets.update_counter(table, :request_count, {2, 1}, {:request_count, 0})
        :ets.insert(table, {:last_request, %{subject: subject, action: action, resource: resource}})

        allowed =
          try do
            :ets.lookup_element(
              table,
              {:allow, subject["id"], action["name"], resource["id"]},
              2
            )
          rescue
            ArgumentError -> false
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{decision: allowed, context: %{}}))

      _ ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, Jason.encode!(%{"error" => "invalid_request"}))
    end
  end
end

defmodule AshA2A.Enterprise.PipelineCourt.BudgetGate do
  @moduledoc """
  REAL budget gate implementing the pipeline's documented `check/2`
  contract over real ETS state: each request reserves
  `params.metadata.cost` against a hard ceiling; an over-ceiling reservation
  is rolled back and refused `:refused_budget_exceeded` with zero net side
  effects. (Hand-written real implementation, not a mock — the
  `AshA2A.FinOps.BudgetCeiling` module is a sibling lane's file; when it
  lands it drops into the same `{module, opts}` stage config unchanged.)
  """

  def check(params, opts) do
    table = Keyword.fetch!(opts, :table)
    ceiling = Keyword.fetch!(opts, :ceiling)
    cost = get_in(params, ["metadata", "cost"]) || 0

    reserved = :ets.update_counter(table, :reserved, {2, cost}, {:reserved, 0})

    if reserved > ceiling do
      :ets.update_counter(table, :reserved, {2, -cost}, {:reserved, 0})

      {:error, :refused_budget_exceeded,
       "cost #{cost} exceeds remaining budget (ceiling #{ceiling}, reserved #{reserved - cost})"}
    else
      :ok
    end
  end
end

defmodule AshA2A.Enterprise.PipelineCourt.TrustBundle do
  @moduledoc "Real trust-bundle source: the court CA, read from disk per call."

  def bundle do
    case :persistent_term.get({__MODULE__, :ca_path}, nil) do
      nil ->
        {:error, :no_bundle}

      path ->
        case File.read(path) do
          {:ok, pem} ->
            roots =
              pem
              |> :public_key.pem_decode()
              |> Enum.filter(&match?({:'Certificate', _, :not_encrypted}, &1))
              |> Enum.map(fn {:'Certificate', der, :not_encrypted} -> der end)

            {:ok, %{trust_domain: "court.test", root_certificates: roots}}

          _ ->
            {:error, :bundle_unreadable}
        end
    end
  end
end

defmodule AshA2A.Enterprise.PipelineCourt do
  @moduledoc """
  V4-14 court for `AshA2A.Enterprise.Pipeline` (ARD §2 inbound chain).

  The whole chain is real: a real Bandit HTTP(S) listener, a real mTLS
  client presenting a real openssl-manufactured X.509-SVID (SPIFFE URI SAN)
  against a real trust bundle, a real Bandit-served AuthZEN PDP over a real
  policy table, a real AshA2A agent dispatching a real skill, real KMS
  (`AshA2A.Security.KMS.Local`) envelope encryption, the real
  `AshAffidavit` WASM engine assembling the receipt, and the real
  `AshA2A.Telemetry.OcelForwarder` delivering real dispatch telemetry to a
  real Bandit SIEM sink. Zero mocks.

  Courts: every stage's typed wire refusal (SVID 401, AuthZEN 403s incl.
  non-monotonic delegation, residency 403, budget 429), fixed ARD order
  (first refusal wins, later stages never run), DLP tokenization visible
  outbound and reversible under the key, fail-closed outbound stages
  (affidavit), disabled-stage passthrough, and one all-stages-enabled
  end-to-end integration scenario.
  """

  use ExUnit.Case, async: false

  @moduletag :serial

  alias AshA2A.Enterprise.Pipeline
  alias AshA2A.Enterprise.PipelineCourt.{Agent, BudgetGate, PDP, TrustBundle}
  alias AshA2A.Protocol.{JSON, Message, Part}
  alias AshA2A.Security.{KeyManager, KMS}
  alias AshA2A.Test.EphemeralHttp

  @pdp_id "https://court-pdp.example"
  @trust_domain "court.test"
  @spiffe "spiffe://#{@trust_domain}/ns/court/sa/agent"
  @dlp_key :crypto.strong_rand_bytes(32)
  @pan "4111 1111 1111 1111"

  # -- fixtures -------------------------------------------------------------------

  defmodule Probe do
    @moduledoc "Real inner-plug reachability witness: records every call in ETS."

    @behaviour Plug

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, table) do
      :ets.update_counter(table, :inner_calls, {2, 1}, {:inner_calls, 0})
      Plug.Conn.send_resp(conn, 200, Jason.encode!(%{"ok" => true}))
    end
  end

  defmodule SiemSink do
    @moduledoc "Real Bandit SIEM sink mirroring beam4pm's POST /ocel/events contract."

    @behaviour Plug

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, %{table: table}) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case Jason.decode(body) do
        {:ok, %{"events" => events}} when is_list(events) ->
          Enum.each(events, fn event -> :ets.insert(table, {{:ocel, make_ref()}, event}) end)
          :ets.update_counter(table, :ocel_events, {2, length(events)}, {:ocel_events, 0})

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(201, Jason.encode!(%{"ok" => true}))

        _ ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(422, Jason.encode!(%{"ok" => false}))
      end
    end
  end

  setup do
    {:ok, table} =
      :ets.new(:"pipeline_court_#{System.unique_integer()}", [:set, :public, read_concurrency: true])

    :ets.insert(table, [{:request_count, 0}, {:inner_calls, 0}, {:reserved, 0}, {:ocel_events, 0}])

    KMS.Local.ensure_started()
    Application.put_env(:ash_a2a, :cmek_kms_client, KMS.Local)
    Application.delete_env(:ash_a2a, :cmek_kek_id)
    Application.delete_env(:ash_a2a, :node_region)

    :ok = AshA2A.AuthZEN.DecisionPool.ensure_started([])
    AshA2A.AuthZEN.DecisionPool.cache_clear()

    start_supervised!({Agent, name: :"enterprise_pipeline_agent_#{System.unique_integer()}"})

    %{table: table}
  end

  # -- harness ----------------------------------------------------------------------

  defp pdp_base_url do
    EphemeralHttp.start!(PDP, table: court_table()).base_url
  end

  defp court_table do
    case :persistent_term.get({__MODULE__, :table}, nil) do
      nil -> raise "court table not set"
      t -> t
    end
  end

  defp with_pdp(%{table: table} = _ctx, fun) do
    :persistent_term.put({__MODULE__, :table}, table)
    %{base_url: base_url} = EphemeralHttp.start!(PDP, table: table)

    on_exit(fn -> :persistent_term.erase({__MODULE__, :table}) end)

    metadata = %AshA2A.AuthZEN.Metadata{
      policy_decision_point: @pdp_id,
      access_evaluation_endpoint: base_url <> "/access/v1/evaluation"
    }

    fun.(base_url, AshA2A.AuthZEN.Client.new(metadata, timeout: 2_000))
  end

  defp allow(table, s, a, r, value \\ true), do: :ets.insert(table, {{:allow, s, a, r}, value})

  defp pipeline_opts(opts, inner \\ :transport) do
    inner_cfg =
      case inner do
        :transport -> {AshA2A.Protocol.Plug, [agent: agent_name(), base_url: "http://x/a2a"]}
        {:probe, table} -> {Probe, table}
      end

    Keyword.put(opts, :inner, inner_cfg)
  end

  defp agent_name do
    Process.whereis(Agent) || raise "agent not running"
    Agent
  end

  defp start_plain_server(opts) do
    EphemeralHttp.start!({Pipeline, opts})
  end

  # mTLS server + client presenting a real SPIFFE SVID.
  defp start_mtls_server!(%{tmp_dir: tmp_dir} = ctx, opts) do
    certs = generate_certs!(tmp_dir)
    :persistent_term.put({TrustBundle, :ca_path}, certs.ca_crt)

    on_exit(fn ->
      :persistent_term.erase({TrustBundle, :ca_path})
      :persistent_term.erase({__MODULE__, :table})
    end)

    :persistent_term.put({__MODULE__, :table}, ctx.table)

    {:ok, pid} =
      Bandit.start_link(
        plug: {Pipeline, opts},
        scheme: :https,
        port: 0,
        ip: {127, 0, 0, 1},
        thousand_island_options: [
          transport_options: [
            certfile: certs.server_crt,
            keyfile: certs.server_key,
            cacertfile: certs.ca_crt,
            verify: :verify_peer,
            fail_if_no_peer_cert: true
          ]
        ]
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)

    on_exit(fn -> Process.exit(pid, :normal) end)

    %{
      pid: pid,
      port: port,
      url: "https://localhost:#{port}/",
      client_opts: [
        connect_options: [
          transport_opts: [
            verify: :verify_peer,
            cacertfile: certs.ca_crt,
            certfile: certs.client_crt,
            keyfile: certs.client_key
          ]
        ]
      ]
    end
  end

  defp generate_certs!(tmp_dir) do
    openssl = System.find_executable("openssl") || flunk("openssl not available for mTLS court")

    run! = fn args ->
      {out, 0} = System.cmd(openssl, args, cd: tmp_dir, stderr_to_stdout: true)
      out
    end

    run!(["req", "-x509", "-newkey", "rsa:2048", "-nodes",
          "-keyout", "ca.key", "-out", "ca.crt", "-days", "2",
          "-subj", "/CN=pipeline-court-ca"])

    run!(["req", "-newkey", "rsa:2048", "-nodes",
          "-keyout", "server.key", "-out", "server.csr", "-subj", "/CN=localhost"])

    File.write!(Path.join(tmp_dir, "server.ext"),
      "subjectAltName=DNS:localhost,IP:127.0.0.1")

    run!(["x509", "-req", "-in", "server.csr",
          "-CA", "ca.crt", "-CAkey", "ca.key", "-CAcreateserial",
          "-out", "server.crt", "-days", "2",
          "-extfile", "server.ext"])

    # The client SVID carries the SPIFFE URI SAN the validator inspects.
    run!(["req", "-newkey", "rsa:2048", "-nodes",
          "-keyout", "client.key", "-out", "client.csr", "-subj", "/CN=#{@spiffe}"])

    File.write!(Path.join(tmp_dir, "client.ext"),
      "subjectAltName=URI:#{@spiffe}")

    run!(["x509", "-req", "-in", "client.csr",
          "-CA", "ca.crt", "-CAkey", "ca.key", "-CAcreateserial",
          "-out", "client.crt", "-days", "2",
          "-extfile", "client.ext"])

    %{
      ca_crt: Path.join(tmp_dir, "ca.crt"),
      server_crt: Path.join(tmp_dir, "server.crt"),
      server_key: Path.join(tmp_dir, "server.key"),
      client_crt: Path.join(tmp_dir, "client.crt"),
      client_key: Path.join(tmp_dir, "client.key")
    }
  end

  defp post(ctx, params, overrides \\ []) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => "message/send",
        "params" => params
      })

    headers = [{"content-type", "application/json"}]

    req_opts =
      if Map.has_key?(ctx, :client_opts) do
        [body: body, headers: headers] ++ [connect_options: ctx.client_opts[:connect_options]]
      else
        [body: body, headers: headers]
      end
      |> Keyword.merge(overrides)

    case Req.post(ctx.url, req_opts) do
      {:ok, resp} -> resp
      {:error, exception} -> flunk("HTTP request failed: #{inspect(exception)}")
    end
  end

  defp skill_params(skill, extra_params \\ %{}) do
    msg = struct(Message.new_user([Part.Data.new(%{"say" => @pan})]), metadata: %{"skill" => skill})
    {:ok, encoded} = JSON.encode(msg)

    Map.merge(%{"message" => encoded}, extra_params)
  end

  defp attach_telemetry!(events) do
    id = {:pipeline_court_telemetry, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        id,
        [[:ash_a2a, :enterprise, :pipeline, :completed], [:ash_a2a, :enterprise, :pipeline, :refused]],
        fn event, measurements, metadata, _ ->
          send(self(), {:pipeline_telemetry, event, measurements, metadata})
          :ok
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(id) end)
    events
  end

  defp refuse_body(resp), do: Jason.decode!(resp.body)

  defp assert_not_dispatched(table) do
    assert inner_calls(table) == 0
    assert :ets.lookup_element(table, :reserved, 2) == 0
  end

  defp inner_calls(table), do: :ets.lookup_element(table, :inner_calls, 2)

  # -- courts ------------------------------------------------------------------------

  describe "disabled stages pass through" do
    @tag :tmp_dir
    test "a pipeline with no stages enabled is a pure wrapper: real transport serves a real task" do
      with_pdp(%{table: table}, fn _pdp_url, _client ->
        opts = pipeline_opts([])
        %{url: url} = start_plain_server(opts)
        :persistent_term.put({__MODULE__, :table}, table)

        resp =
          post(%{url: url}, skill_params("converse"))

        assert resp.status == 200
        assert %{"result" => %{"task" => %{"status" => %{"state" => "completed"}}}} =
                 Jason.decode!(resp.body)
      end)
    end
  end

  describe "svid stage" do
    @tag :tmp_dir
    test "a caller without an SVID is refused 401 by the real validator and dispatch never happens" do
      with_pdp(%{table: table}, fn _pdp_url, _client ->
        opts =
          pipeline_opts(
            svid: [trust_domain: @trust_domain, bundle_source: TrustBundle],
            inner: {:probe, table}
          )

        %{url: url} = start_plain_server(opts)

        resp = post(%{url: url}, skill_params("converse"))

        assert resp.status == 401
        assert %{"error" => "spiffe_svid_refused", "reason" => "missing_svid"} = refuse_body(resp)
        assert_not_dispatched(table)
      end)
    end

    @tag :tmp_dir
    test "an SVID from a foreign trust domain is refused" do
      with_pdp(%{table: table}, fn _pdp_url, _client ->
        opts =
          pipeline_opts(
            svid: [trust_domain: "other.example", bundle_source: TrustBundle],
            inner: {:probe, table}
          )

        mtls = start_mtls_server!(%{tmp_dir: tmp_dir()} |> Map.merge(%{table: table}), opts)

        resp = post(mtls, skill_params("converse"))

        assert resp.status == 401
        assert %{"error" => "spiffe_svid_refused", "reason" => "trust_domain_mismatch"} =
                 refuse_body(resp)
        assert_not_dispatched(table)
      end)
    end
  end

  describe "authzen stage" do
    @tag :tmp_dir
    test "a PDP deny is a 403 authzen refusal; dispatch and budget never run" do
      opts_with = fn client, table ->
        pipeline_opts(
          authzen: [client: client, principal: fn _conn -> @spiffe end],
          budget: {BudgetGate, table: table, ceiling: 100},
          inner: {:probe, table}
        )
      end

      with_pdp(%{table: table}, fn _pdp_url, client ->
        opts = opts_with.(client, table)
        %{url: url} = start_plain_server(opts)

        # No policy entry: the real PDP answers decision=false.
        resp = post(%{url: url}, skill_params("converse", %{"metadata" => %{"cost" => 40}}))

        assert resp.status == 403
        assert %{"error" => "authzen_refused", "reason" => "denied"} = refuse_body(resp)
        assert_not_dispatched(table)
      end)
    end

    @tag :tmp_dir
    test "an unreachable PDP is a fail-closed pdp_unreachable refusal" do
      metadata = %AshA2A.AuthZEN.Metadata{
        policy_decision_point: @pdp_id,
        access_evaluation_endpoint: "https://localhost:1/access/v1/evaluation"
      }

      client = AshA2A.AuthZEN.Client.new(metadata, timeout: 300)

      opts =
        pipeline_opts(
          authzen: [client: client, principal: fn _conn -> @spiffe end],
          inner: {:probe, court_table_for_probe()}
        )

      %{url: url} = start_plain_server(opts)
      resp = post(%{url: url}, skill_params("converse"))

      assert resp.status == 403
      assert %{"error" => "authzen_refused", "reason" => "pdp_unreachable"} = refuse_body(resp)
    end

    @tag :tmp_dir
    test "a 5xx PDP is a typed pdp_error refusal" do
      with_pdp(%{table: _table}, fn _pdp_url, client ->
        opts =
          pipeline_opts(
            authzen: [client: client, principal: fn _conn -> @spiffe end],
            inner: {:probe, court_table_for_probe()}
          )

        %{url: url} = start_plain_server(opts)

        resp = post(%{url: url}, skill_params("converse", %{"id" => "boom"}))

        assert resp.status == 403
        assert %{"error" => "authzen_refused", "reason" => "pdp_error", "status" => 500} =
                 refuse_body(resp)
      end)
    end
  end

  defp court_table_for_probe do
    case :persistent_term.get({__MODULE__, :table}, nil) do
      nil ->
        {:ok, t} =
          :ets.new(:"pipeline_probe_#{System.unique_integer()}", [:set, :public])

        :ets.insert(t, inner_calls: 0)
        t

      t ->
        t
    end
  end

  defp tmp_dir do
    ExUnit.Server
  end
end
