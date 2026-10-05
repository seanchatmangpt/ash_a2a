# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Enterprise.PipelineCourt.Converse do
  @moduledoc """
  Real fixture resource for the V4-14 pipeline court: one generic `:converse`
  action requiring `:say` (completes when present), the suite's established
  owner-scope fixture shape.
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
  Real Bandit-served AuthZEN PDP over a real ETS policy table. Resource id
  `"boom"` answers 500 (adversarial fixture, the AuthZEN client court's
  convention). Every request increments a real counter.
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

        :ets.insert(
          table,
          {:last_request, %{subject: subject, action: action, resource: resource}}
        )

        if resource["id"] == "boom" do
          json(conn, 500, %{error: "internal"})
        else
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

          json(conn, 200, %{decision: allowed, context: %{}})
        end

      _ ->
        json(conn, 400, %{error: "invalid_request"})
    end
  end

  defp json(conn, status, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(payload))
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
              |> Enum.filter(&match?({:Certificate, _, :not_encrypted}, &1))
              |> Enum.map(fn {:Certificate, der, :not_encrypted} -> der end)

            {:ok, %{trust_domain: "court.test", root_certificates: roots}}

          _ ->
            {:error, :bundle_unreadable}
        end
    end
  end
end

defmodule AshA2A.Enterprise.PipelineCourt.Probe do
  @moduledoc "Real inner-plug reachability witness: counts every call in ETS."

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, table) do
    :ets.update_counter(table, :inner_calls, {2, 1}, {:inner_calls, 0})
    Plug.Conn.send_resp(conn, 200, Jason.encode!(%{"ok" => true}))
  end
end

defmodule AshA2A.Enterprise.PipelineCourt.SiemSink do
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

defmodule AshA2A.Enterprise.PipelineCourt do
  @moduledoc """
  V4-14 court for `AshA2A.Enterprise.Pipeline` (ARD §2 inbound chain).

  Everything is real: a real Bandit HTTP(S) listener, a real mTLS client
  presenting a real openssl-manufactured X.509-SVID (SPIFFE URI SAN) against
  a real trust bundle, a real Bandit-served AuthZEN PDP over a real policy
  table, a real AshA2A agent dispatching a real skill, the real
  `AshA2A.FinOps.BudgetEnforcer` + `BudgetStore` hard-ceiling reservation,
  real KMS (`AshA2A.Security.KMS.Local`) envelope encryption, the real
  `AshAffidavit` WASM engine assembling the receipt, and the real
  `AshA2A.Telemetry.OcelForwarder` delivering real dispatch telemetry to a
  real Bandit SIEM sink. Zero mocks.

  Courts: every stage's typed wire refusal (SVID 401, AuthZEN 403s incl.
  the non-monotonic delegation refusal, residency 403, budget 429), the
  fixed ARD order (first refusal wins; later stages never run), DLP
  tokenization visible outbound and reversible under the key, fail-closed
  outbound stages, disabled-stage passthrough, and one all-stages-enabled
  end-to-end integration scenario.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag timeout: 180_000

  alias AshA2A.AuthZEN.{Client, Metadata}
  alias AshA2A.Enterprise.Pipeline
  alias AshA2A.Enterprise.PipelineCourt.{Agent, Probe, PDP, SiemSink, TrustBundle}
  alias AshA2A.Protocol.{JSON, Message, Part}
  alias AshA2A.Security.KMS
  alias AshA2A.Test.EphemeralHttp

  @pdp_id "https://court-pdp.example"
  @trust_domain "court.test"
  @spiffe "spiffe://#{@trust_domain}/ns/court/sa/agent"
  @dlp_key :crypto.strong_rand_bytes(32)
  @pan "4111 1111 1111 1111"
  @ssn "123-45-6789"

  setup ctx do
    table =
      :ets.new(:"pipeline_court_#{System.unique_integer()}", [
        :set,
        :public,
        read_concurrency: true
      ])

    :ets.insert(table, [{:request_count, 0}, {:inner_calls, 0}, {:ocel_events, 0}])

    KMS.Local.ensure_started()
    Application.put_env(:ash_a2a, :cmek_kms_client, KMS.Local)
    Application.delete_env(:ash_a2a, :cmek_kek_id)
    Application.delete_env(:ash_a2a, :node_region)

    :ok = AshA2A.AuthZEN.DecisionPool.ensure_started([])
    AshA2A.AuthZEN.DecisionPool.cache_clear()

    agent = :"pipeline_court_agent_#{System.unique_integer([:positive])}"
    start_supervised!({Agent, name: agent})

    Map.merge(ctx, %{table: table, agent: agent})
  end

  # -- harness ----------------------------------------------------------------------

  defp start_pdp!(table) do
    %{base_url: base_url} = EphemeralHttp.start!({PDP, %{table: table}})

    metadata = %Metadata{
      policy_decision_point: @pdp_id,
      access_evaluation_endpoint: base_url <> "/access/v1/evaluation"
    }

    {base_url, Client.new(metadata, timeout: 2_000)}
  end

  defp allow(table, s, a, r, value \\ true), do: :ets.insert(table, {{:allow, s, a, r}, value})

  defp plain_server!(opts) do
    %{base_url: url} = EphemeralHttp.start!({Pipeline, opts})
    %{url: url}
  end

  defp mtls_server!(tmp_dir, opts) do
    certs = generate_certs!(tmp_dir)
    :persistent_term.put({TrustBundle, :ca_path}, certs.ca_crt)

    on_exit(fn -> :persistent_term.erase({TrustBundle, :ca_path}) end)

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
      url: "https://localhost:#{port}/",
      card_url: "https://localhost:#{port}/.well-known/agent-card.json",
      client_opts: [
        verify: :verify_peer,
        cacertfile: certs.ca_crt,
        certfile: certs.client_crt,
        keyfile: certs.client_key
      ]
    }
  end

  defp generate_certs!(tmp_dir) do
    openssl = System.find_executable("openssl") || flunk("openssl not available for mTLS court")

    run! = fn args ->
      {out, 0} = System.cmd(openssl, args, cd: tmp_dir, stderr_to_stdout: true)
      out
    end

    run!.([
      "req",
      "-x509",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-keyout",
      "ca.key",
      "-out",
      "ca.crt",
      "-days",
      "2",
      "-subj",
      "/CN=pipeline-court-ca"
    ])

    run!.([
      "req",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-keyout",
      "server.key",
      "-out",
      "server.csr",
      "-subj",
      "/CN=localhost"
    ])

    File.write!(Path.join(tmp_dir, "server.ext"), "subjectAltName=DNS:localhost,IP:127.0.0.1")

    run!.([
      "x509",
      "-req",
      "-in",
      "server.csr",
      "-CA",
      "ca.crt",
      "-CAkey",
      "ca.key",
      "-CAcreateserial",
      "-out",
      "server.crt",
      "-days",
      "2",
      "-extfile",
      "server.ext"
    ])

    # The client SVID carries the SPIFFE URI SAN the validator inspects.
    run!.([
      "req",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-keyout",
      "client.key",
      "-out",
      "client.csr",
      "-subj",
      "/CN=pipeline-court-client"
    ])

    File.write!(Path.join(tmp_dir, "client.ext"), "subjectAltName=URI:#{@spiffe}")

    run!.([
      "x509",
      "-req",
      "-in",
      "client.csr",
      "-CA",
      "ca.crt",
      "-CAkey",
      "ca.key",
      "-CAcreateserial",
      "-out",
      "client.crt",
      "-days",
      "2",
      "-extfile",
      "client.ext"
    ])

    %{
      ca_crt: Path.join(tmp_dir, "ca.crt"),
      server_crt: Path.join(tmp_dir, "server.crt"),
      server_key: Path.join(tmp_dir, "server.key"),
      client_crt: Path.join(tmp_dir, "client.crt"),
      client_key: Path.join(tmp_dir, "client.key")
    }
  end

  defp req_opts(server, extra \\ []) do
    base =
      if Map.has_key?(server, :client_opts) do
        [connect_options: [transport_opts: server.client_opts]]
      else
        []
      end

    Keyword.merge(Keyword.put(base, :decode_body, false), extra)
  end

  defp post(server, params) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => "message/send",
        "params" => params
      })

    task =
      Task.async(fn ->
        Req.post(
          server.url,
          req_opts(server, body: body, headers: [{"content-type", "application/json"}])
        )
      end)

    case Task.yield(task, 30_000) do
      {:ok, {:ok, resp}} ->
        resp

      {:ok, {:error, exception}} ->
        flunk("HTTP request failed: #{inspect(exception)}")

      nil ->
        Task.shutdown(task, :kill)
        flunk("HTTP request hung >30s to #{server.url}")
    end
  end

  defp skill_params(skill, extra_params \\ %{}) do
    msg =
      struct(Message.new_user([Part.Data.new(%{"say" => @pan})]), metadata: %{"skill" => skill})

    {:ok, encoded} = JSON.encode(msg)

    Map.merge(%{"message" => encoded}, extra_params)
  end

  defp attach_pipeline_telemetry! do
    id = {:pipeline_court_telemetry, System.unique_integer([:positive])}
    parent = self()

    :ok =
      :telemetry.attach_many(
        id,
        [
          [:ash_a2a, :enterprise, :pipeline, :completed],
          [:ash_a2a, :enterprise, :pipeline, :refused]
        ],
        fn event, measurements, metadata, _ ->
          send(parent, {:pipeline_telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  # Resp bodies are raw JSON bytes (decode_body: false); decode once here.
  defp wire(resp), do: if(is_map(resp.body), do: resp.body, else: Jason.decode!(resp.body))

  defp inner_calls(table), do: :ets.lookup_element(table, :inner_calls, 2)

  defp assert_not_dispatched(table) do
    assert inner_calls(table) == 0
  end

  defp stop_affidavit_pool! do
    case Process.whereis(AshAffidavit.Pool) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)

        GenServer.stop(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          5_000 -> :ok
        end
    end
  end

  # -- courts ------------------------------------------------------------------------

  describe "disabled stages pass through" do
    @tag :tmp_dir
    test "a pipeline with no stages enabled is a pure wrapper: real transport serves a real task",
         %{
           table: table,
           agent: agent
         } do
      {_pdp_url, _client} = start_pdp!(table)

      opts = [
        inner: {AshA2A.Protocol.Plug, agent: agent, base_url: "http://x/a2a"}
      ]

      %{url: url} = plain_server!(opts)
      resp = post(%{url: url}, skill_params("converse"))

      assert resp.status == 200

      assert %{"result" => %{"task" => %{"status" => %{"state" => "TASK_STATE_COMPLETED"}}}} =
               wire(resp)
    end
  end

  describe "svid stage" do
    @tag :tmp_dir
    test "a caller without an SVID is refused 401 by the real validator; dispatch never happens",
         %{
           table: table,
           tmp_dir: tmp_dir
         } do
      certs = generate_certs!(tmp_dir)
      :persistent_term.put({TrustBundle, :ca_path}, certs.ca_crt)
      on_exit(fn -> :persistent_term.erase({TrustBundle, :ca_path}) end)

      opts = [
        svid: [trust_domain: @trust_domain, bundle_source: TrustBundle],
        inner: {Probe, table}
      ]

      %{url: url} = plain_server!(opts)
      resp = post(%{url: url}, skill_params("converse"))

      assert resp.status == 401
      assert %{"error" => "spiffe_svid_refused", "reason" => "missing_svid"} = wire(resp)
      assert_not_dispatched(table)
    end

    @tag :tmp_dir
    test "an SVID from a foreign trust domain is refused over real mTLS", %{tmp_dir: tmp_dir} do
      opts = [
        svid: [trust_domain: "other.example", bundle_source: TrustBundle],
        inner: {Probe, self()}
      ]

      mtls = mtls_server!(tmp_dir, opts)
      resp = post(mtls, skill_params("converse"))

      assert resp.status == 401
      assert %{"error" => "spiffe_svid_refused", "reason" => "trust_domain_mismatch"} = wire(resp)
    end
  end

  describe "authzen stage" do
    @tag :tmp_dir
    test "a PDP deny is a 403 authzen refusal; dispatch and budget never run", %{
      table: table
    } do
      {_url, client} = start_pdp!(table)
      store = start_store!()

      opts = [
        authzen: [client: client, principal: fn _conn -> @spiffe end],
        budget: [store: store, estimated_tokens: 40],
        inner: {Probe, table}
      ]

      %{url: url} = plain_server!(opts)

      resp =
        post(%{url: url}, %{
          "message" => say_message(),
          "cost_center" => "cc-court",
          "budget_account_id" => "acct-court"
        })

      assert resp.status == 403
      assert %{"error" => "authzen_refused", "reason" => "denied"} = wire(resp)
      assert_not_dispatched(table)
      assert AshA2A.FinOps.BudgetStore.usage(store, "acct-court") == 0
    end

    @tag :tmp_dir
    test "an unreachable PDP is a fail-closed pdp_unreachable refusal", %{agent: agent} do
      metadata = %Metadata{
        policy_decision_point: @pdp_id,
        access_evaluation_endpoint: "https://localhost:1/access/v1/evaluation"
      }

      client = Client.new(metadata, timeout: 300)

      opts = [
        authzen: [client: client, principal: fn _conn -> @spiffe end],
        inner: {AshA2A.Protocol.Plug, agent: agent, base_url: "http://x/a2a"}
      ]

      %{url: url} = plain_server!(opts)
      resp = post(%{url: url}, skill_params("converse"))

      assert resp.status == 403
      assert %{"error" => "authzen_refused", "reason" => "pdp_unreachable"} = wire(resp)
    end

    @tag :tmp_dir
    test "a 5xx PDP answer is a typed pdp_error refusal", %{table: table} do
      {_url, client} = start_pdp!(table)

      opts = [
        authzen: [client: client, principal: fn _conn -> @spiffe end],
        inner: {Probe, table}
      ]

      %{url: url} = plain_server!(opts)

      resp = post(%{url: url}, skill_params("converse", %{"id" => "boom"}))

      assert resp.status == 403

      assert %{"error" => "authzen_refused", "reason" => "pdp_error", "status" => 500} =
               wire(resp)
    end

    @tag :tmp_dir
    test "a decision from another PDP is a pdp_mixup refusal", %{table: table} do
      {_url, client} = start_pdp!(table)

      opts = [
        authzen: [
          client: client,
          expected_pdp: "https://some-other-pdp.example",
          principal: fn _conn -> @spiffe end
        ],
        inner: {Probe, table}
      ]

      %{url: url} = plain_server!(opts)

      allow(table, @spiffe, "converse", "task")
      resp = post(%{url: url}, skill_params("converse"))

      assert resp.status == 403
      assert %{"error" => "authzen_refused", "reason" => "pdp_mixup"} = wire(resp)
    end

    @tag :tmp_dir
    test "an attempted privilege escalation over a delegation chain is the typed non-monotonic refusal",
         %{
           table: table,
           agent: agent
         } do
      {_url, client} = start_pdp!(table)

      opts = [
        authzen: [client: client, principal: fn _conn -> @spiffe end],
        inner: {AshA2A.Protocol.Plug, agent: agent, base_url: "http://x/a2a"}
      ]

      %{url: url} = plain_server!(opts)
      allow(table, @spiffe, "converse", "task")

      # The delegated child presents an inherited scope that does NOT include
      # the capability it requests: escalation, refused before any dispatch.
      params =
        skill_params("converse", %{
          "metadata" => %{"delegation" => %{"effective" => ["read_docs"]}}
        })

      resp = post(%{url: url}, params)

      assert resp.status == 403

      assert %{
               "error" => "authzen_refused",
               "reason" => "refused_non_monotonic_grant",
               "excess" => ["converse"],
               "digest" => digest
             } = wire(resp)

      assert is_binary(digest) and String.starts_with?(digest, "sha256:")
    end

    @tag :tmp_dir
    test "a delegated task inside its inherited scope is admitted end to end", %{
      table: table,
      agent: agent
    } do
      {_url, client} = start_pdp!(table)

      opts = [
        authzen: [client: client, principal: fn _conn -> @spiffe end],
        inner: {AshA2A.Protocol.Plug, agent: agent, base_url: "http://x/a2a"}
      ]

      %{url: url} = plain_server!(opts)
      allow(table, @spiffe, "converse", "task")

      params =
        skill_params("converse", %{
          "metadata" => %{"delegation" => %{"effective" => ["converse", "read_docs"]}}
        })

      resp = post(%{url: url}, params)

      assert resp.status == 200

      assert %{"result" => %{"task" => %{"status" => %{"state" => "TASK_STATE_COMPLETED"}}}} =
               wire(resp)
    end

    @tag :tmp_dir
    test "no verified identity at all is a 401 identity_absent refusal", %{table: table} do
      {_url, client} = start_pdp!(table)

      opts = [
        authzen: [client: client],
        inner: {Probe, table}
      ]

      %{url: url} = plain_server!(opts)
      resp = post(%{url: url}, skill_params("converse"))

      assert resp.status == 401
      assert %{"error" => "authzen_refused", "reason" => "identity_absent"} = wire(resp)
    end
  end

  describe "residency stage" do
    @tag :tmp_dir
    test "an EU-tagged request on a us-east-1 node is a typed residency refusal", %{table: table} do
      opts = [
        residency: [node_region: "us-east-1"],
        inner: {Probe, table}
      ]

      %{url: url} = plain_server!(opts)

      resp =
        post(%{url: url}, %{
          "message" => say_message(),
          "metadata" => %{"data_jurisdiction" => "EU"}
        })

      assert resp.status == 403

      assert %{
               "error" => "refused_data_residency_violation",
               "stage" => "residency",
               "detail" => _
             } =
               wire(resp)
    end

    @tag :tmp_dir
    test "a matching residency tag passes and dispatches", %{table: table, agent: agent} do
      {_url, _client} = start_pdp!(table)

      opts = [
        residency: [node_region: "us-east-1"],
        inner: {AshA2A.Protocol.Plug, agent: agent, base_url: "http://x/a2a"}
      ]

      %{url: url} = plain_server!(opts)

      resp =
        post(%{url: url}, %{
          "message" => skill_message_raw("converse"),
          "metadata" => %{"data_jurisdiction" => "US"}
        })

      assert resp.status == 200

      assert %{"result" => %{"task" => %{"status" => %{"state" => "TASK_STATE_COMPLETED"}}}} =
               wire(resp)
    end

    @tag :tmp_dir
    test "a tagged request on a node of unknown region is refused fail-closed", %{table: table} do
      opts = [
        residency: [],
        inner: {Probe, table}
      ]

      %{url: url} = plain_server!(opts)

      resp =
        post(%{url: url}, %{
          "message" => say_message(),
          "metadata" => %{"data_jurisdiction" => "EU"}
        })

      assert resp.status == 403

      assert %{"error" => "refused_data_residency_unknown_region", "stage" => "residency"} =
               wire(resp)

      assert_not_dispatched(table)
    end
  end

  describe "budget stage (real AshA2A.FinOps gate)" do
    @tag :tmp_dir
    test "a hard-ceiling breach is a 429 budget_exceeded refusal with zero reservation", %{
      table: table
    } do
      store = AshA2A.FinOps.BudgetStore.new([])
      AshA2A.FinOps.BudgetStore.set_budget(store, "acct-court", 10)

      opts = [
        budget: [store: store, estimated_tokens: 40],
        inner: {Probe, table}
      ]

      %{url: url} = plain_server!(opts)

      resp =
        post(%{url: url}, %{
          "message" => say_message(),
          "cost_center" => "cc-court",
          "budget_account_id" => "acct-court"
        })

      assert resp.status == 429
      assert %{"error" => "budget_exceeded", "stage" => "budget"} = wire(resp)
      assert_not_dispatched(table)
      assert AshA2A.FinOps.BudgetStore.usage(store, "acct-court") == 0
    end

    @tag :tmp_dir
    test "missing cost attribution is the enforcer's typed invalid_request refusal", %{
      table: table
    } do
      store = AshA2A.FinOps.BudgetStore.new([])
      AshA2A.FinOps.BudgetStore.set_budget(store, "acct-court", 100)

      opts = [
        budget: [store: store, estimated_tokens: 40],
        inner: {Probe, table}
      ]

      %{url: url} = plain_server!(opts)

      resp = post(%{url: url}, %{"message" => say_message()})

      assert resp.status == 400
      assert %{"error" => "invalid_request", "stage" => "budget"} = wire(resp)
      assert_not_dispatched(table)
    end

    @tag :tmp_dir
    test "an enabled budget gate whose module is not loaded refuses fail-closed 503", %{
      table: table
    } do
      opts = [
        budget: {AshA2A.Enterprise.PipelineCourt.NoSuchBudgetModule, []},
        inner: {Probe, table}
      ]

      %{url: url} = plain_server!(opts)

      resp = post(%{url: url}, skill_params("converse"))

      assert resp.status == 503

      assert %{"error" => "refused_budget_gate_unavailable", "stage" => "budget"} =
               wire(resp)

      assert_not_dispatched(table)
    end
  end

  describe "dlp stage" do
    @tag :tmp_dir
    test "PAN and SSN are tokenized outbound and reversible under the key", %{
      table: table,
      agent: agent
    } do
      {_url, _client} = start_pdp!(table)

      opts = [
        dlp: [key: @dlp_key, entropy_floor: 6.0],
        inner: {AshA2A.Protocol.Plug, agent: agent, base_url: "http://x/a2a"}
      ]

      %{url: url} = plain_server!(opts)

      msg =
        struct(
          Message.new_user([Part.Data.new(%{"say" => "pay #{@pan} or #{@ssn}"})]),
          metadata: %{"skill" => "converse"}
        )

      {:ok, encoded} = JSON.encode(msg)
      resp = post(%{url: url}, %{"message" => encoded})

      assert resp.status == 200
      assert resp.body =~ "dlt1_"
      refute resp.body =~ @pan
      refute resp.body =~ @ssn

      # Real reversibility: the key holder recovers the exact plaintexts.
      restored = Jason.encode!(AshA2A.Security.DLPFilter.restore(wire(resp), key: @dlp_key))
      assert restored =~ @pan
      assert restored =~ @ssn
    end
  end

  describe "fixed ARD order" do
    @tag :tmp_dir
    test "the first refusing stage answers: authzen denial wins over later residency/budget violations",
         %{
           table: table
         } do
      {_url, client} = start_pdp!(table)
      store = AshA2A.FinOps.BudgetStore.new([])
      AshA2A.FinOps.BudgetStore.set_budget(store, "acct-court", 10)

      opts = [
        authzen: [client: client, principal: fn _conn -> @spiffe end],
        residency: [node_region: "us-east-1"],
        budget: [store: store, estimated_tokens: 40],
        inner: {Probe, table}
      ]

      %{url: authzen_url} = plain_server!(opts)

      violating = %{
        "message" => say_message(),
        "metadata" => %{"data_jurisdiction" => "EU"},
        "cost_center" => "cc-court",
        "budget_account_id" => "acct-court"
      }

      resp = post(%{url: authzen_url}, violating)

      assert resp.status == 403
      assert %{"error" => "authzen_refused", "reason" => "denied"} = wire(resp)
      assert_not_dispatched(table)
      assert AshA2A.FinOps.BudgetStore.usage(store, "acct-court") == 0

      # The same violating request with authzen disabled stops at residency:
      # order is structural, each stage still owns its typed error.
      residency_opts = [
        residency: [node_region: "us-east-1"],
        budget: [store: store, estimated_tokens: 40],
        inner: {Probe, table}
      ]

      %{url: residency_url} = plain_server!(residency_opts)
      resp2 = post(%{url: residency_url}, violating)

      assert resp2.status == 403

      assert %{"error" => "refused_data_residency_violation", "stage" => "residency"} =
               wire(resp2)
    end
  end

  describe "affidavit stage (fail-closed outbound)" do
    @tag :tmp_dir
    test "an enabled affidavit stage with no engine pool refuses the response 500", %{
      table: table,
      agent: agent
    } do
      stop_affidavit_pool!()

      {_url, _client} = start_pdp!(table)

      opts = [
        affidavit: [],
        inner: {AshA2A.Protocol.Plug, agent: agent, base_url: "http://x/a2a"}
      ]

      %{url: url} = plain_server!(opts)

      attach_pipeline_telemetry!()
      resp = post(%{url: url}, skill_params("converse"))

      assert resp.status == 500

      assert %{"error" => "refused_affidavit_receipt_failed", "stage" => "outbound"} =
               wire(resp)

      assert_receive {:pipeline_telemetry, [:ash_a2a, :enterprise, :pipeline, :refused], _,
                      %{stage: :outbound}},
                     5_000
    end
  end

  describe "end-to-end integration (all stages enabled, real mTLS)" do
    @tag :tmp_dir
    test "SVID -> AuthZEN -> DLP -> residency -> budget -> dispatch -> DLP out -> CMEK -> affidavit -> OCEL",
         %{
           table: table,
           agent: agent,
           tmp_dir: tmp_dir
         } do
      {_pdp_url, client} = start_pdp!(table)
      allow(table, @spiffe, "converse", "task")

      store = AshA2A.FinOps.BudgetStore.new([])
      AshA2A.FinOps.BudgetStore.set_budget(store, "acct-court", 100)

      # Real SIEM sink + real OcelForwarder egress.
      %{base_url: sink_base} = EphemeralHttp.start!({SiemSink, %{table: table}})
      Application.put_env(:ash_a2a, :ocel_ingest_url, sink_base <> "/ocel/events")

      on_exit(fn -> Application.delete_env(:ash_a2a, :ocel_ingest_url) end)

      # Real WASM affidavit engine.
      if Process.whereis(AshAffidavit.Pool) do
        :ok
      else
        start_supervised!({AshAffidavit.Pool, size: 2})
      end

      opts = [
        svid: [trust_domain: @trust_domain, bundle_source: TrustBundle],
        authzen: [client: client],
        dlp: [key: @dlp_key, entropy_floor: 6.0],
        residency: [node_region: "us-east-1"],
        budget: [store: store, estimated_tokens: 40],
        cmek: [],
        affidavit: [],
        ocel: [],
        inner: {AshA2A.Protocol.Plug, agent: agent, base_url: "http://x/a2a"}
      ]

      mtls = mtls_server!(tmp_dir, opts)
      attach_pipeline_telemetry!()

      delivered_before = AshA2A.Telemetry.OcelForwarder.delivered_count()

      params =
        skill_params("converse", %{
          "metadata" => %{"data_jurisdiction" => "US"},
          "cost_center" => "cc-court",
          "budget_account_id" => "acct-court"
        })

      resp = post(mtls, params)

      assert resp.status == 200
      decoded = wire(resp)

      assert %{"result" => %{"task" => %{"status" => %{"state" => "TASK_STATE_COMPLETED"}}}} =
               decoded

      # DLP: tokenized on the wire, reversible under the key.
      assert resp.body =~ "dlt1_"
      refute resp.body =~ @pan
      restored = Jason.encode!(AshA2A.Security.DLPFilter.restore(decoded, key: @dlp_key))
      assert restored =~ @pan

      # Budget: the real enforcer reserved the estimate.
      assert AshA2A.FinOps.BudgetStore.usage(store, "acct-court") == 40

      # AuthZEN: the real PDP was consulted exactly once.
      assert :ets.lookup_element(table, :request_count, 2) == 1

      # Outbound chain: CMEK envelope + affidavit receipt.
      assert get_resp_header(resp, "x-a2a-affidavit-digest") != []

      assert_receive {:pipeline_telemetry, [:ash_a2a, :enterprise, :pipeline, :completed],
                      _measurements, %{cmek: envelope, affidavit: assembled}},
                     5_000

      assert %{"receipt" => receipt} = assembled
      assert {:ok, true} = AshA2A.Evidence.Affidavit.verify_receipt(receipt)

      # The envelope decrypts back to the exact wire body (at-rest == on-wire).
      assert {:ok, plaintext} = AshA2A.Security.KeyManager.decrypt(envelope)
      assert plaintext == resp.body

      # OCEL: real dispatch telemetry forwarded to the real SIEM sink.
      wait_for_ocel(table, 5_000)
      assert :ets.lookup_element(table, :ocel_events, 2) >= 1
      assert AshA2A.Telemetry.OcelForwarder.delivered_count() > delivered_before

      events = :ets.match(table, {{:ocel, :_}, :"$1"})
      assert Enum.any?(events, fn [event] -> event["attributes"]["skill_name"] == "converse" end)

      # The mTLS pipeline also serves the agent card (SVID required, gates pass).
      card = Req.get!(mtls.card_url, req_opts(mtls))
      assert card.status == 200
    end
  end

  defp wait_for_ocel(table, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    poll(table, deadline)
  end

  defp poll(table, deadline) do
    if :ets.lookup_element(table, :ocel_events, 2) >= 1 do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("no OCEL event landed at the SIEM sink within the deadline")
      end

      Process.sleep(25)
      poll(table, deadline)
    end
  end

  defp get_resp_header(resp, name) do
    case Enum.find(resp.headers, fn {k, _} -> String.downcase(k) == name end) do
      {_, value} -> [value]
      nil -> []
    end
  end

  defp say_message do
    skill_message_raw("converse")
  end

  defp skill_message_raw(skill) do
    msg =
      struct(Message.new_user([Part.Data.new(%{"say" => "hello"})]),
        metadata: %{"skill" => skill}
      )

    {:ok, encoded} = JSON.encode(msg)
    encoded
  end

  defp start_store! do
    store = AshA2A.FinOps.BudgetStore.new([])
    AshA2A.FinOps.BudgetStore.set_budget(store, "acct-court", 100)
    store
  end
end
