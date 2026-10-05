# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Enterprise.SIEMTest do
  @moduledoc """
  SIEM egress court (PRD v26.10.4 FR-06.4).

  Every claim is witnessed on the wire by a REAL local HTTP receiver: a real
  Bandit listener per platform, a real `Req.post` from the adapter, a real
  captured request body asserted on directly. Zero mocks.

  Witnessed here:

    * per-platform wire contracts -- Splunk HEC (`Authorization: Splunk`,
      `/services/collector/event`, `{"time","event"}` ndjson), Chronicle
      (`X-Goog-Api-Key`, `/v2/logs?log_type=`, raw OCEL v2 ndjson lines),
      Datadog (`DD-API-KEY`, `/api/v2/logs`, log items whose `message` is
      the OCEL v2 ndjson line);
    * the payload is the IEEE OCEL v2 serialization of
      `AshA2A.Telemetry.OcelForwarder` / `AshA2A.SemanticProjection.ocel_event/1`,
      consumed read-only (Chronicle lines round-trip equal to the input map);
    * batch boundaries (`:batch_size` -> one request per batch, in order) and
      fail-fast flush semantics (typed error names the failed batch, the
      flushed batches and the unflushed remainder);
    * resilience -- a first-attempt 500 followed by success is retried and
      delivered; exhaustion is bounded (`1 + :max_retries` requests, no
      more); non-retryable 4xx fails on its first attempt; transport
      refusal to a dead port collapses into the typed
      `{:error, {:siem_delivery_failed, platform, reason}}` without raising;
    * fail-closed config validation -- missing credentials, bad endpoints,
      bad retry/batch integers, missing mTLS files and malformed OCEL
      events are refused BEFORE any HTTP request leaves (receiver count
      stays at zero);
    * real mTLS: an openssl-generated CA + server + client certificate
      chain, a Bandit TLS listener with `verify: :verify_peer` and
      `fail_if_no_peer_cert: true`. Delivering WITHOUT a client cert is
      refused in the TLS handshake; delivering WITH the client cert lands
      the event -- proving the client certificate was actually sent.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Telemetry.SIEM
  alias AshA2A.Telemetry.SIEM.{Chronicle, DatadogLogs, SplunkHEC}

  @store AshA2A.Enterprise.SIEMTest.Store

  # -- real receiver -----------------------------------------------------------

  defmodule SIEMReceiver do
    @moduledoc """
    Real Plug.Router standing in for all three SIEM platforms (routed by
    path), capturing every raw request into a real Agent store and
    answering with each platform's real success status/body. Failure
    injection (`fail_next`, `deny_next`, `fail_from`) is test-controlled
    state in the same store -- real 500/403 responses over real HTTP, not
    stubbed clients.
    """

    use Plug.Router

    @store AshA2A.Enterprise.SIEMTest.Store

    plug(:match)
    plug(:dispatch)

    post _ do
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      status =
        Agent.get_and_update(@store, fn st ->
          index = length(st.requests) + 1

          entry = %{
            path: conn.request_path,
            query: conn.query_string,
            headers: conn.req_headers,
            body: body
          }

          st = %{st | requests: st.requests ++ [entry]}

          cond do
            st.deny_next > 0 ->
              st = %{st | deny_next: st.deny_next - 1}
              {403, st}

            st.fail_next > 0 ->
              st = %{st | fail_next: st.fail_next - 1}
              {500, st}

            is_integer(st.fail_from) and index >= st.fail_from ->
              {500, st}

            true ->
              {ok_status(conn.request_path), st}
          end
        end)

      conn |> Plug.Conn.send_resp(status, resp_body(conn.request_path))
    end

    match(_) do
      conn |> Plug.Conn.send_resp(404, "route_not_admitted")
    end

    defp ok_status("/services/collector/event"), do: 200
    defp ok_status("/v2/logs"), do: 200
    defp ok_status("/api/v2/logs"), do: 202

    defp resp_body("/services/collector/event"),
      do: ~s({"text":"Success","code":0})

    defp resp_body("/v2/logs"), do: ~s({})
    defp resp_body(_), do: ""
  end

  # The Agent is `start_link`ed to the test process, so it begins dying the
  # moment the test process exits -- concurrently with this `on_exit/1`
  # callback, which ExUnit runs in a separate process afterwards. Stop by
  # pid, tolerate it already being gone, and wait for the real `:DOWN` so
  # the name is unregistered before the next test's `start_link` can run.
  defp stop_named_agent(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      agent ->
        ref = Process.monitor(agent)

        try do
          Agent.stop(agent)
        catch
          :exit, _already_gone -> :ok
        end

        receive do
          {:DOWN, ^ref, :process, ^agent, _reason} -> :ok
        after
          5_000 -> :ok
        end
    end
  end

  defp start_receiver! do
    {:ok, _} = Agent.start_link(fn -> fresh_store() end, name: @store)
    http = AshA2A.Test.EphemeralHttp.start!(SIEMReceiver)

    on_exit(fn ->
      Process.exit(http.pid, :normal)
      stop_named_agent(@store)
    end)

    http.base_url
  end

  defp fresh_store, do: %{requests: [], fail_next: 0, deny_next: 0, fail_from: nil}

  defp requests, do: Agent.get(@store, & &1.requests)

  defp set_store!(updates), do: Agent.update(@store, &Map.merge(&1, Map.new(updates)))

  # -- fixtures -----------------------------------------------------------------

  defp ocel_event(i) do
    %{
      "event_id" => "evt-#{i}",
      "event_type" => "ash_a2a.receipt.committed",
      "event_time" => "2026-10-04T00:00:0#{rem(i, 10)}Z",
      "attributes" => %{"capability_id" => "cap-#{i}"},
      "relationships" => [%{"qualifier" => "acted_on", "object_id" => "task-#{i}"}]
    }
  end

  defp events(n), do: Enum.map(1..n, &ocel_event/1)

  defp config(endpoint, platform_overrides \\ []) do
    Keyword.merge(
      [
        endpoint: endpoint,
        max_retries: 2,
        backoff_base_ms: 1,
        max_backoff_ms: 5
      ],
      platform_overrides
    )
  end

  defp ndjson_lines(body) do
    body
    |> String.split("\n")
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Jason.decode!/1)
  end

  defp header(headers, name) do
    case List.keyfind(headers, name, 0) do
      {^name, value} -> value
      nil -> flunk("expected header #{name} in #{inspect(headers)}")
    end
  end

  # -- per-platform wire contracts ----------------------------------------------

  describe "Splunk HEC wire contract" do
    test "token auth, /services/collector/event, OCEL v2 events inside {time,event} ndjson" do
      endpoint = start_receiver!()
      payload = events(3)

      assert {:ok, report} =
               SIEM.deliver(:splunk_hec, payload, config(endpoint, token: "test-hec-token-123"))

      assert report == %{
               platform: :splunk_hec,
               events: 3,
               batches: 1,
               http_requests: 1,
               attempts: 1
             }

      assert [req] = requests()
      assert req.path == "/services/collector/event"
      assert header(req.headers, "authorization") == "Splunk test-hec-token-123"
      assert header(req.headers, "content-type") == "application/x-ndjson"

      lines = ndjson_lines(req.body)
      assert length(lines) == 3

      for {line, i} <- Enum.with_index(lines, 1) do
        assert %{"time" => time, "event" => event, "sourcetype" => "ash_a2a:ocel:v2"} = line
        assert is_float(time)
        assert event == ocel_event(i)
      end
    end
  end

  describe "Chronicle wire contract" do
    test "X-Goog-Api-Key, /v2/logs?log_type=, raw OCEL v2 ndjson lines consumed read-only" do
      endpoint = start_receiver!()
      payload = events(2)

      assert {:ok, report} =
               SIEM.deliver(:chronicle, payload, config(endpoint, api_key: "chronicle-key-xyz"))

      assert report.platform == :chronicle
      assert report.http_requests == 1

      assert [req] = requests()
      assert req.path == "/v2/logs"
      assert header(req.headers, "x-goog-api-key") == "chronicle-key-xyz"
      assert header(req.headers, "content-type") == "application/x-ndjson"
      assert URI.decode_query(req.query)["log_type"] == "ASH_A2A_OCEL"

      lines = ndjson_lines(req.body)
      assert lines == payload
    end

    test "log_type override reaches the ingestion API as a query parameter" do
      endpoint = start_receiver!()

      assert {:ok, _} =
               SIEM.deliver(
                 :chronicle,
                 events(1),
                 config(endpoint, api_key: "k", log_type: "ASH_A2A_DISPATCH")
               )

      assert [req] = requests()
      assert URI.decode_query(req.query)["log_type"] == "ASH_A2A_DISPATCH"
    end
  end

  describe "Datadog Logs wire contract" do
    test "DD-API-KEY, /api/v2/logs, message is the OCEL v2 ndjson line" do
      endpoint = start_receiver!()
      payload = events(2)

      assert {:ok, report} =
               SIEM.deliver(
                 :datadog_logs,
                 payload,
                 config(endpoint, api_key: "dd-key-abc", service: "ash_a2a_prod")
               )

      assert report.platform == :datadog_logs
      assert report.http_requests == 1

      assert [req] = requests()
      assert req.path == "/api/v2/logs"
      assert header(req.headers, "dd-api-key") == "dd-key-abc"
      assert header(req.headers, "content-type") == "application/json"

      assert %{"data" => data} = Jason.decode!(req.body)
      assert length(data) == 2

      for {item, i} <- Enum.with_index(data, 1) do
        assert %{"type" => "log", "attributes" => attrs} = item
        assert attrs["service"] == "ash_a2a_prod"
        assert attrs["ddsource"] == "ash_a2a"
        assert attrs["status"] == "info"
        assert Jason.decode!(attrs["message"]) == ocel_event(i)
      end
    end
  end

  # -- batch + flush semantics ----------------------------------------------------

  describe "batch and flush semantics" do
    test "batch_size 2 over 3 events -> two requests in order (2 lines, then 1)" do
      endpoint = start_receiver!()

      assert {:ok, report} =
               SIEM.deliver(:splunk_hec, events(3), config(endpoint, token: "t", batch_size: 2))

      assert report.batches == 2
      assert report.http_requests == 2
      assert report.attempts == 2

      assert [first, second] = requests()
      assert length(ndjson_lines(first.body)) == 2
      assert length(ndjson_lines(second.body)) == 1
      assert [only_line] = ndjson_lines(second.body)
      assert only_line["event"]["event_id"] == "evt-3"
    end

    test "fail-fast flush: batch 2 of 3 fails -> typed error names batch, flushed, unflushed" do
      endpoint = start_receiver!()
      set_store!(fail_from: 2)

      assert {:error, {:siem_delivery_failed, :splunk_hec, detail}} =
               SIEM.deliver(
                 :splunk_hec,
                 events(3),
                 config(endpoint, token: "t", batch_size: 1, max_retries: 1)
               )

      assert detail.batch == 2
      assert detail.flushed_batches == 1
      assert detail.unflushed_events == 1
      # batch 1 succeeded once; batch 2 tried 1 + 1 retries
      assert detail.attempts == 1 + 2

      # receiver saw exactly: 1 delivered + 2 attempts on batch 2
      assert length(requests()) == 3
    end

    test "empty event list sends nothing and returns a zero report" do
      endpoint = start_receiver!()

      assert {:ok, report} = SIEM.deliver(:splunk_hec, [], config(endpoint, token: "t"))

      assert report == %{
               platform: :splunk_hec,
               events: 0,
               batches: 0,
               http_requests: 0,
               attempts: 0
             }

      assert requests() == []
    end
  end

  # -- resilient delivery ------------------------------------------------------------

  describe "resilient delivery" do
    test "first attempt 500 then success: retried with backoff and delivered" do
      endpoint = start_receiver!()
      set_store!(fail_next: 1)

      assert {:ok, report} =
               SIEM.deliver(:splunk_hec, events(1), config(endpoint, token: "t"))

      assert report.attempts == 2
      assert report.http_requests == 1
      assert length(requests()) == 2
    end

    test "exhaustion is bounded: fail_from 1 with max_retries 2 -> exactly 3 attempts, typed error" do
      endpoint = start_receiver!()
      set_store!(fail_from: 1)

      assert {:error, {:siem_delivery_failed, :chronicle, detail}} =
               SIEM.deliver(:chronicle, events(1), config(endpoint, api_key: "k", max_retries: 2))

      assert detail.attempts == 3
      assert detail.batch == 1
      assert match?({:http_status, 500}, detail.reason)
      assert length(requests()) == 3
    end

    test "non-retryable 403 fails on its first attempt (no second request)" do
      endpoint = start_receiver!()
      set_store!(deny_next: 1)

      assert {:error, {:siem_delivery_failed, :datadog_logs, detail}} =
               SIEM.deliver(
                 :datadog_logs,
                 events(1),
                 config(endpoint, api_key: "k", max_retries: 2)
               )

      assert detail.attempts == 1
      assert match?({:http_status, 403}, detail.reason)
      assert length(requests()) == 1
    end

    test "transport refusal to a dead port -> typed error, never raises" do
      start_receiver!()

      assert {:error, {:siem_delivery_failed, :splunk_hec, detail}} =
               SIEM.deliver(:splunk_hec, events(1),
                 endpoint: "http://127.0.0.1:1",
                 token: "t",
                 max_retries: 1,
                 backoff_base_ms: 1,
                 max_backoff_ms: 2
               )

      assert match?({:transport, _kind}, detail.reason)
      assert detail.attempts == 2
      assert requests() == []
    end

    test "an adapter raise collapses into the typed error; the broadcaster never crashes" do
      defmodule RaisingAdapter do
        @behaviour AshA2A.Telemetry.SIEM

        @impl true
        def platform, do: :splunk_hec

        @impl true
        def validate_config(_config), do: {:ok, []}

        @impl true
        def send_events(_events, _config), do: raise("boom")
      end

      assert {:error, {:siem_delivery_failed, :splunk_hec, {:raised, summary}}} =
               SIEM.deliver(RaisingAdapter, events(1), [])

      assert match?(%{kind: :exception}, summary)
    end
  end

  # -- fail-closed validation ------------------------------------------------------

  describe "fail-closed config validation" do
    test "missing per-platform credentials are refused before any HTTP" do
      endpoint = start_receiver!()

      assert {:error, {:siem_config_invalid, :splunk_hec, {:missing_credential, :token}}} =
               SIEM.deliver(:splunk_hec, events(1), config(endpoint))

      assert {:error, {:siem_config_invalid, :chronicle, {:missing_credential, :api_key}}} =
               SIEM.deliver(:chronicle, events(1), config(endpoint))

      assert {:error, {:siem_config_invalid, :datadog_logs, {:missing_credential, :api_key}}} =
               SIEM.deliver(:datadog_logs, events(1), config(endpoint))

      assert requests() == []
    end

    test "bad endpoint, bad integers and unknown platform are refused" do
      start_receiver!()

      assert {:error, {:siem_config_invalid, :splunk_hec, :endpoint_missing}} =
               SIEM.deliver(:splunk_hec, events(1), token: "t")

      assert {:error, {:siem_config_invalid, :splunk_hec, {:invalid_endpoint, :scheme_or_host}}} =
               SIEM.deliver(:splunk_hec, events(1), endpoint: "ftp://127.0.0.1:1", token: "t")

      assert {:error,
              {:siem_config_invalid, :splunk_hec, {:max_retries, :not_a_non_negative_integer}}} =
               SIEM.deliver(:splunk_hec, events(1),
                 endpoint: "http://127.0.0.1:1",
                 token: "t",
                 max_retries: -1
               )

      assert {:error, {:siem_config_invalid, :splunk_hec, {:batch_size, :not_a_positive_integer}}} =
               SIEM.deliver(:splunk_hec, events(1),
                 endpoint: "http://127.0.0.1:1",
                 token: "t",
                 batch_size: 0
               )

      assert {:error, :unknown_platform} =
               SIEM.deliver(:graylog, events(1), endpoint: "http://127.0.0.1:1")

      assert requests() == []
    end

    test "mTLS transport_opts fail closed on a missing file and on a non-keyword" do
      start_receiver!()
      missing = Path.join(System.tmp_dir!(), "no-such-cert-#{System.unique_integer()}.pem")

      assert {:error,
              {:siem_config_invalid, :splunk_hec,
               {:transport_opts_file_missing, :certfile, ^missing}}} =
               SIEM.deliver(:splunk_hec, events(1),
                 endpoint: "http://127.0.0.1:1",
                 token: "t",
                 transport_opts: [certfile: missing]
               )

      assert {:error, {:siem_config_invalid, :splunk_hec, {:transport_opts, :not_a_keyword}}} =
               SIEM.deliver(:splunk_hec, events(1),
                 endpoint: "http://127.0.0.1:1",
                 token: "t",
                 transport_opts: ["certfile.pem"]
               )

      assert requests() == []
    end

    test "malformed OCEL events are refused before any HTTP" do
      endpoint = start_receiver!()

      bad_event = %{"event_id" => "evt-1", "event_time" => "2026-10-04T00:00:00Z"}
      missing = Map.delete(ocel_event(1), "event_type")

      assert {:error, {:siem_invalid_event, :splunk_hec, 1, ["event_type"]}} =
               SIEM.deliver(:splunk_hec, [missing], config(endpoint, token: "t"))

      assert {:error, {:siem_invalid_event, :chronicle, 1, missing_keys}} =
               SIEM.deliver(:chronicle, [bad_event], config(endpoint, api_key: "k"))

      assert Enum.sort(missing_keys) == ["event_type"]

      assert {:error, {:siem_invalid_event, :datadog_logs, 1, ["not_a_map"]}} =
               SIEM.deliver(:datadog_logs, ["nope"], config(endpoint, api_key: "k"))

      assert requests() == []
    end
  end

  # -- behaviour surface -------------------------------------------------------------

  describe "behaviour surface" do
    test "adapters resolve from platform atoms and from modules; unknown is refused" do
      assert {:ok, SplunkHEC} = SIEM.adapter(:splunk_hec)
      assert {:ok, Chronicle} = SIEM.adapter(:chronicle)
      assert {:ok, DatadogLogs} = SIEM.adapter(:datadog_logs)
      assert {:ok, SplunkHEC} = SIEM.adapter(SplunkHEC)
      assert {:error, :unknown_platform} = SIEM.adapter(:graylog)
      assert {:error, :unknown_platform} = SIEM.adapter("splunk")
    end

    test "adapters implement the behaviour" do
      assert {:ok, _} =
               SplunkHEC.validate_config(endpoint: "https://splunk.example:8088", token: "t")

      assert {:ok, _} =
               Chronicle.validate_config(
                 endpoint: "https://malachiteingestion-pa.googleapis.com",
                 api_key: "k"
               )

      assert {:ok, _} =
               DatadogLogs.validate_config(
                 endpoint: "https://http-intake.logs.datadoghq.com",
                 api_key: "k"
               )
    end
  end

  # -- real mTLS ------------------------------------------------------------------------

  describe "real mTLS via harness transport_opts" do
    @describetag :tmp_dir

    test "server demands a client certificate: no cert fails the handshake, cert delivers",
         %{tmp_dir: tmp_dir} do
      certs = generate_certs!(tmp_dir)

      {:ok, pid} =
        Bandit.start_link(
          plug: SIEMReceiver,
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

      {:ok, _} = Agent.start_link(fn -> fresh_store() end, name: @store)

      payload = events(1)

      # Without a client certificate the mTLS handshake is refused by the
      # real server; the typed delivery failure surfaces it, no raise.
      assert {:error, {:siem_delivery_failed, :splunk_hec, detail}} =
               SIEM.deliver(:splunk_hec, payload,
                 endpoint: "https://localhost:#{port}",
                 token: "t",
                 max_retries: 0,
                 transport_opts: [verify: :verify_peer, cacertfile: certs.ca_crt]
               )

      assert match?({:transport, _}, detail.reason)

      # With the harness-supplied client certificate the same delivery lands.
      assert {:ok, report} =
               SIEM.deliver(:splunk_hec, payload,
                 endpoint: "https://localhost:#{port}",
                 token: "t",
                 max_retries: 0,
                 transport_opts: [
                   verify: :verify_peer,
                   cacertfile: certs.ca_crt,
                   certfile: certs.client_crt,
                   keyfile: certs.client_key
                 ]
               )

      assert report.http_requests == 1

      assert [req] = requests()
      assert req.path == "/services/collector/event"
      assert header(req.headers, "authorization") == "Splunk t"
      assert [%{"event" => %{"event_id" => "evt-1"}}] = ndjson_lines(req.body)
    end
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
      "/CN=siem-test-ca"
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
      "/CN=siem-test-client"
    ])

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
      "2"
    ])

    %{
      ca_crt: Path.join(tmp_dir, "ca.crt"),
      server_crt: Path.join(tmp_dir, "server.crt"),
      server_key: Path.join(tmp_dir, "server.key"),
      client_crt: Path.join(tmp_dir, "client.crt"),
      client_key: Path.join(tmp_dir, "client.key")
    }
  end
end
