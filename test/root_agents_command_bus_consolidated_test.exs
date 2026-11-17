# NOTE: 14 module(s) removed from this consolidated file because the repaired originals (kept as separate files) define the same modules; see docs/reference/test-consolidation-merge.md.
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT

# ==============================================================================
# Consolidated Test Suite: Root Agents Command Bus
# Target File 1 of Worker 01
# Consolidated from 22 source files:
#   - test/agent_card_serving_test.exs
#   - test/agent_state_and_longpoll_test.exs
#   - test/application_supervision_wiring_test.exs
#   - test/artifact_only_generation_guard_test.exs
#   - test/ash_a2a_a2a_methods_test.exs
#   - test/ash_a2a_actuation_identity_test.exs
#   - test/ash_a2a_agent_command_bus_test.exs
#   - test/ash_a2a_agent_moduledoc_test.exs
#   - test/ash_a2a_agent_multi_turn_carry_test.exs
#   - test/ash_a2a_agent_multi_turn_test.exs
#   - test/ash_a2a_agent_semantic_replan_test.exs
#   - test/ash_a2a_agent_semantic_request_test.exs
#   - test/ash_a2a_agent_semantic_router_wiring_test.exs
#   - test/ash_a2a_airo_description_test.exs
#   - test/ash_a2a_application_test.exs
#   - test/ash_a2a_architecture_verifier_chicago_rollup_test.exs
#   - test/ash_a2a_architecture_verifier_test.exs
#   - test/ash_a2a_authority_capability_grant_test.exs
#   - test/ash_a2a_authority_confused_deputy_test.exs
#   - test/ash_a2a_authority_decision_failclosed_test.exs
#   - test/ash_a2a_authority_killer_negative_test.exs
#   - test/ash_a2a_authority_non_implications_test.exs
# ==============================================================================

# --- SECTION 1: Original test/agent_card_serving_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.AgentCardServingTest do
  @moduledoc """
  W9 items 4, 5, 6 and 7: Agent Card serving hardening.

    * conditional GET (`If-None-Match` weak/list/`*`, `If-Modified-Since`) ->
      `304` carrying the same cache headers, on all three card routes, with a
      stable (init-time) `Last-Modified`, proven end to end by a real
      `AshA2A.Protocol.CardCache` revalidating against a real Bandit listener;
    * serve-time card signing (`:sign_with`), stable bytes and `ETag`;
    * `tasks/list` `totalSize` is the pre-pagination count under
      `:authorize_task`;
    * `capabilities.extendedAgentCard` / `pushNotifications` follow the
      configured provider / push state without dropping the card's other
      capabilities.

  Real conns, real agent GenServer, real HTTP listener. No mocks, no sleeps.
  """

  use ExUnit.Case, async: true

  alias AshA2A.A2ATransport.Plug, as: A2ATransportPlug
  alias AshA2A.Protocol.CardSigning
  alias AshA2A.Protocol.Plug.CardServe
  alias AshA2A.Test.EphemeralHttp
  alias AshA2A.Test.PlugFixture.GreeterAgent

  @card_path "/.well-known/agent-card.json"
  @fixed_lm ~U[2026-01-02 03:04:05Z]
  @fixed_lm_http "Fri, 02 Jan 2026 03:04:05 GMT"
  @key "w9-shared-secret-0123456789abcdef"

  setup do
    agent = :"w9_card_agent_#{System.unique_integer([:positive])}"
    {:ok, pid} = GreeterAgent.start_link(name: agent)
    on_exit(fn -> AshA2A.TestSupport.SafeStop.stop(pid) end)
    %{agent: agent}
  end

  defp base(agent, extra \\ []),
    do: [agent: agent, base_url: "http://localhost:4000/a2a", last_modified: @fixed_lm] ++ extra

  defp get_card(mod, opts, headers \\ []) do
    :get
    |> Plug.Test.conn(@card_path)
    |> Plug.Conn.merge_req_headers(headers)
    |> mod.call(opts)
  end

  defp header(conn, name), do: conn |> Plug.Conn.get_resp_header(name) |> List.first()

  # {label, module, opts, expected cache-control}
  defp card_plugs(agent, extra \\ []) do
    [
      {"Protocol.Plug", AshA2A.Protocol.Plug, AshA2A.Protocol.Plug.init(base(agent, extra)),
       "public, max-age=300"},
      {"A2ATransport.Plug", A2ATransportPlug, A2ATransportPlug.init(base(agent, extra)),
       "public, max-age=300"},
      {"Transport.Plug", AshA2A.Transport.Plug, AshA2A.Transport.Plug.init(base(agent, extra)),
       "max-age=60"}
    ]
  end

  describe "conditional GET" do
    test "200 carries ETag, a stable Last-Modified and Cache-Control", %{agent: agent} do
      for {label, mod, opts, cache_control} <- card_plugs(agent) do
        first = get_card(mod, opts)
        second = get_card(mod, opts)

        assert first.status == 200, label
        assert [etag] = Plug.Conn.get_resp_header(first, "etag")
        assert etag =~ ~r/^"[0-9a-f]+"$/
        assert header(first, "last-modified") == @fixed_lm_http, label
        assert header(first, "cache-control") == cache_control, label

        # Last-Modified is init-time, not request-time: identical across requests.
        assert header(second, "last-modified") == header(first, "last-modified")
        assert header(second, "etag") == etag
      end
    end

    test "matching If-None-Match (exact, weak, in a list, *) answers 304 with the same headers",
         %{agent: agent} do
      for {label, mod, opts, cache_control} <- card_plugs(agent) do
        ok = get_card(mod, opts)
        etag = header(ok, "etag")

        for validator <- [etag, "W/" <> etag, ~s("nope", ) <> etag, ~s(W/"nope",W/) <> etag, "*"] do
          conn = get_card(mod, opts, [{"if-none-match", validator}])

          assert conn.status == 304, "#{label} #{validator}"
          assert conn.resp_body == ""
          assert header(conn, "etag") == etag
          assert header(conn, "last-modified") == @fixed_lm_http
          assert header(conn, "cache-control") == cache_control
        end
      end
    end

    test "non-matching If-None-Match answers 200 with the full card", %{agent: agent} do
      for {label, mod, opts, _} <- card_plugs(agent) do
        conn = get_card(mod, opts, [{"if-none-match", ~s("not-the-etag")}])
        assert conn.status == 200, label
        assert %{"name" => _} = Jason.decode!(conn.resp_body)
      end
    end

    test "If-Modified-Since: not-newer -> 304, older -> 200, garbage -> 200", %{agent: agent} do
      for {label, mod, opts, _} <- card_plugs(agent) do
        same = get_card(mod, opts, [{"if-modified-since", @fixed_lm_http}])
        assert same.status == 304, label
        assert same.resp_body == ""
        assert header(same, "last-modified") == @fixed_lm_http

        later = get_card(mod, opts, [{"if-modified-since", "Sat, 03 Jan 2026 00:00:00 GMT"}])
        assert later.status == 304, label

        older = get_card(mod, opts, [{"if-modified-since", "Thu, 01 Jan 2026 00:00:00 GMT"}])
        assert older.status == 200, label

        garbage = get_card(mod, opts, [{"if-modified-since", "yesterday-ish"}])
        assert garbage.status == 200, label
      end
    end

    test "If-None-Match takes precedence over If-Modified-Since", %{agent: agent} do
      for {label, mod, opts, _} <- card_plugs(agent) do
        etag = header(get_card(mod, opts), "etag")

        # INM present and not matching: 200 even though IMS alone would 304.
        mismatch =
          get_card(mod, opts, [
            {"if-none-match", ~s("other")},
            {"if-modified-since", @fixed_lm_http}
          ])

        assert mismatch.status == 200, label

        # INM matching: 304 even though IMS alone would 200.
        match =
          get_card(mod, opts, [
            {"if-none-match", etag},
            {"if-modified-since", "Thu, 01 Jan 2026 00:00:00 GMT"}
          ])

        assert match.status == 304, label
      end
    end

    test "the HTTP-date helpers round-trip and reject malformed dates" do
      assert CardServe.http_date(@fixed_lm) == @fixed_lm_http
      assert {:ok, unix} = CardServe.parse_http_date(@fixed_lm_http)
      assert unix == DateTime.to_unix(@fixed_lm)
      assert CardServe.parse_http_date("Fri, 31 Feb 2026 03:04:05 GMT") == :error
      assert CardServe.parse_http_date("Fri, 02 Foo 2026 03:04:05 GMT") == :error
      assert CardServe.parse_http_date("nonsense") == :error
    end

    test "a real CardCache revalidates a stale entry against a real server and gets 304", %{
      agent: agent
    } do
      server =
        EphemeralHttp.start!(
          {AshA2A.Protocol.Plug, [agent: agent, base_url: "http://127.0.0.1:1/a2a"]}
        )

      cache_dir =
        Path.join(System.tmp_dir!(), "w9-card-cache-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf(cache_dir) end)

      assert {:ok, card, :fresh} =
               AshA2A.Protocol.CardCache.fetch(server.base_url, cache_dir: cache_dir)

      assert is_binary(card.name)

      # max_age: 0 makes the stored entry stale, forcing a conditional GET with
      # the stored ETag; the plug answers 304 and the cache reports it.
      assert {:ok, revalidated, :not_modified} =
               AshA2A.Protocol.CardCache.fetch(server.base_url, cache_dir: cache_dir, max_age: 0)

      assert revalidated.name == card.name
    end
  end

  describe "card signing (:sign_with)" do
    test "serves a signed card with stable bytes and a stable ETag", %{agent: agent} do
      sign_with = [key: @key, alg: :HS256, kid: "w9-k1"]

      for {label, mod, opts, _} <- card_plugs(agent, sign_with: sign_with) do
        first = get_card(mod, opts)
        second = get_card(mod, opts)

        assert first.status == 200, label
        card = Jason.decode!(first.resp_body)
        assert [%{"protected" => _, "signature" => _}] = card["signatures"]

        # The signature verifies against the served bytes' wire card.
        assert CardSigning.verify(card, @key) == :ok
        assert {:error, _} = CardSigning.verify(card, "a-different-secret-0123456789abcdef")

        assert second.resp_body == first.resp_body, label
        assert header(second, "etag") == header(first, "etag"), label

        # ... and conditional GET works on the signed representation.
        revalidated = get_card(mod, opts, [{"if-none-match", header(first, "etag")}])
        assert revalidated.status == 304, label
      end
    end

    test "unsigned plugs serve no signatures member", %{agent: agent} do
      for {label, mod, opts, _} <- card_plugs(agent) do
        card = mod |> get_card(opts) |> Map.fetch!(:resp_body) |> Jason.decode!()
        refute match?([_ | _], card["signatures"]), label
      end
    end
  end

  describe "tasks/list totalSize under :authorize_task" do
    defp list(opts, params) do
      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tasks/list",
          "params" => params
        })

      :post
      |> Plug.Test.conn("/", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> AshA2A.Protocol.Plug.call(opts)
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()
      |> Map.fetch!("result")
    end

    defp send_task(opts) do
      {:ok, message} =
        AshA2A.Protocol.JSON.encode(AshA2A.Protocol.Message.new_user("hello"))

      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "message/send",
          "params" => %{"message" => message}
        })

      :post
      |> Plug.Test.conn("/", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> AshA2A.Protocol.Plug.call(opts)
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()
      |> get_in(["result", "task", "id"])
    end

    test "totalSize is the pre-pagination count, not the page length", %{agent: agent} do
      allow_all =
        AshA2A.Protocol.Plug.init(base(agent, authorize_task: fn _op, _task, _ctx -> :ok end))

      ids = for _ <- 1..3, do: send_task(allow_all)
      assert length(Enum.uniq(ids)) == 3

      page = list(allow_all, %{"pageSize" => 2})
      assert length(page["tasks"]) == 2
      assert page["pageSize"] == 2
      assert page["totalSize"] == 3
      assert page["nextPageToken"] != ""
    end

    test "denied tasks on the page are subtracted from the total, never below the page", %{
      agent: agent
    } do
      allow_all =
        AshA2A.Protocol.Plug.init(base(agent, authorize_task: fn _op, _task, _ctx -> :ok end))

      for _ <- 1..3, do: send_task(allow_all)

      [first | _] = list(allow_all, %{"pageSize" => 2})["tasks"]
      denied_id = first["id"]

      deny_one =
        AshA2A.Protocol.Plug.init(
          base(agent,
            authorize_task: fn _op, task, _ctx ->
              if task.id == denied_id, do: false, else: :ok
            end
          )
        )

      page = list(deny_one, %{"pageSize" => 2})
      assert length(page["tasks"]) == 1
      refute Enum.any?(page["tasks"], &(&1["id"] == denied_id))
      assert page["totalSize"] == 2
      assert page["pageSize"] == 2
    end
  end

  describe "capability consistency" do
    def extended(_identity, card), do: {:ok, card}

    defp capabilities(mod, opts),
      do:
        mod
        |> get_card(opts)
        |> Map.fetch!(:resp_body)
        |> Jason.decode!()
        |> Map.fetch!("capabilities")

    test "extendedAgentCard follows the :extended_card provider both ways", %{agent: agent} do
      with_provider = A2ATransportPlug.init(base(agent, extended_card: &__MODULE__.extended/2))
      without = A2ATransportPlug.init(base(agent))

      # Even a card whose own capabilities claim an extended card must not
      # advertise one the plug would answer -32007 for.
      lying =
        A2ATransportPlug.init(
          base(agent,
            agent_card_opts: [capabilities: %{streaming: true, extended_agent_card: true}]
          )
        )

      assert capabilities(A2ATransportPlug, with_provider)["extendedAgentCard"] == true
      assert capabilities(A2ATransportPlug, without)["extendedAgentCard"] == false
      assert capabilities(A2ATransportPlug, lying)["extendedAgentCard"] == false
    end

    test "the card's other capabilities survive the transport overlay", %{agent: agent} do
      plain = AshA2A.Protocol.Plug.init(base(agent))
      overlaid = A2ATransportPlug.init(base(agent, extended_card: &__MODULE__.extended/2))

      plain_caps = capabilities(AshA2A.Protocol.Plug, plain)
      caps = capabilities(A2ATransportPlug, overlaid)

      assert caps["streaming"] == plain_caps["streaming"]
      assert caps["extendedAgentCard"] == true
    end

    test "pushNotifications is advertised only when push is actually served", %{agent: agent} do
      transport = :"w9_card_transport_#{System.unique_integer([:positive])}"
      start_supervised!({AshA2A.A2ATransport, name: transport})

      on = A2ATransportPlug.init(base(agent, push_notifications: true, transport: transport))
      off = A2ATransportPlug.init(base(agent, push_notifications: false, transport: transport))

      assert capabilities(A2ATransportPlug, on)["pushNotifications"] == true
      refute capabilities(A2ATransportPlug, off)["pushNotifications"] == true
    end
  end
end


# --- SECTION 2: Original test/agent_state_and_longpoll_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.AgentStateLongPoll.Agent do
  @moduledoc false
  use AshA2A.Protocol.Agent,
    name: "x4-agent",
    description: "pauses on ask/auth, completes otherwise",
    capabilities: %{user_artifacts: true}

  alias AshA2A.Protocol.{Message, Part}

  @impl AshA2A.Protocol.Agent
  def handle_message(message, _ctx) do
    case Message.text(message) do
      "ask" -> {:input_required, [Part.Text.new("more?")]}
      "auth" -> {:error, {:auth_required, [Part.Text.new("login")]}}
      _ -> {:reply, [Part.Text.new("ok")]}
    end
  end
end

defmodule AshA2A.AgentStateLongPoll.Pipeline do
  @moduledoc "Stamps the identity named by the x-test-identity header (default alice)."

  @behaviour Plug

  def init(opts) when is_map(opts), do: opts
  def init(opts), do: AshA2A.Transport.HTTPJSON.init(opts)

  def call(conn, opts) do
    who =
      case Plug.Conn.get_req_header(conn, "x-test-identity") do
        [id | _] -> id
        [] -> "alice"
      end

    conn = AshA2A.Protocol.Plug.Auth.put_identity(conn, %{identity: who})
    AshA2A.Transport.HTTPJSON.call(conn, opts)
  end
end

defmodule AshA2A.AgentStateAndLongPollTest do
  @moduledoc """
  X4 court: long-poll cap and timeout, foreign-owner 404, paused-state stream
  lifetime, blocking send at input-required, cancel of a completed task,
  `lastChunk` -> `end_generation`, and the server artifact role default.
  Real Bandit, real agent, real `Req`; waits are deadline-bounded observations.
  """

  use ExUnit.Case, async: false

  @moduletag :serial_shard

  alias AshA2A.Protocol.{Artifact, ClientArtifacts, Message, Part}
  alias AshA2A.Test.EphemeralHttp
  alias AshA2A.AgentStateLongPoll.{Agent, Pipeline}

  @v11 [{"a2a-version", "1.1"}]
  @deadline_ms 5_000

  setup do
    start_supervised!({Agent, []})

    versions = Enum.uniq(AshA2A.Protocol.Version.supported_default() ++ ["1.0", "1.1"])
    opts = [agent: Agent, base_url: "http://127.0.0.1/x4", versions: versions]

    previous = Application.get_env(:ash_a2a, :long_poll_timeout_ms)
    Application.put_env(:ash_a2a, :long_poll_timeout_ms, 400)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ash_a2a, :long_poll_timeout_ms, previous),
        else: Application.delete_env(:ash_a2a, :long_poll_timeout_ms)
    end)

    {:ok, server: EphemeralHttp.start!({Pipeline, Pipeline.init(opts)})}
  end

  # -- helpers -------------------------------------------------------------------

  defp wire(text), do: AshA2A.Protocol.JSON.encode!(Message.new_user([Part.Text.new(text)]))

  defp send_message(server, message, headers \\ @v11) do
    Req.post!(
      url: server.base_url <> "/message:send",
      json: %{"message" => message},
      headers: headers,
      retry: false
    )
  end

  defp new_task(server, text) do
    resp = send_message(server, wire(text))
    assert %{"task" => %{"id" => id} = task} = resp.body
    {id, task}
  end

  defp gen(%{"generation" => g}) do
    {n, ""} = g |> to_string() |> Integer.parse()
    n
  end

  defp frames(buffer) do
    buffer
    |> String.split("\n\n")
    |> Enum.drop(-1)
    |> Enum.flat_map(fn
      "data: " <> json -> [Jason.decode!(json)]
      _comment -> []
    end)
  end

  defp open_sse(url, json) do
    parent = self()
    ref = make_ref()

    task =
      Task.async(fn ->
        Req.request!(
          method: :post,
          url: url,
          json: json,
          headers: @v11,
          retry: false,
          receive_timeout: 20_000,
          into: fn {:data, data}, {req, resp} ->
            send(parent, {:sse, ref, data})
            {:cont, {req, resp}}
          end
        )
      end)

    on_exit(fn -> Process.exit(task.pid, :kill) end)
    {ref, task}
  end

  defp collect_until(ref, buffer, pred) do
    deadline = System.monotonic_time(:millisecond) + @deadline_ms
    do_collect(ref, buffer, pred, deadline)
  end

  defp do_collect(ref, buffer, pred, deadline) do
    all = frames(buffer)

    if pred.(all) do
      {all, buffer}
    else
      remaining = deadline - System.monotonic_time(:millisecond)
      if remaining <= 0, do: flunk("deadline; frames so far: #{inspect(all)}")

      receive do
        {:sse, ^ref, data} -> do_collect(ref, buffer <> data, pred, deadline)
      after
        remaining -> flunk("deadline; frames so far: #{inspect(all)}")
      end
    end
  end

  defp state_of(frame) do
    get_in(frame, ["statusUpdate", "status", "state"]) ||
      get_in(frame, ["task", "status", "state"])
  end

  defp has_state?(frames, state), do: Enum.any?(frames, &(state_of(&1) == state))

  # -- long-poll cap -----------------------------------------------------------------

  test "per-call long-poll wait is capped at the configured maximum" do
    assert ClientArtifacts.long_poll_timeout_ms(60_000) == 400
    assert ClientArtifacts.long_poll_timeout_ms(100) == 100
    assert ClientArtifacts.long_poll_timeout_ms(0) == 0
    assert ClientArtifacts.long_poll_timeout_ms(nil) == 400
    assert ClientArtifacts.long_poll_timeout_ms(-5) == 400
  end

  # -- HTTP long-poll timeout + foreign owner ------------------------------------------

  test "long-poll at the current generation returns the unchanged task at the timeout", %{
    server: server
  } do
    {id, task} = new_task(server, "ask")
    generation = gen(task)

    started = System.monotonic_time(:millisecond)

    resp =
      Req.get!(
        url: server.base_url <> "/tasks/#{id}?currentGeneration=#{generation}",
        headers: @v11,
        retry: false,
        receive_timeout: 15_000
      )

    elapsed = System.monotonic_time(:millisecond) - started

    assert resp.status == 200
    assert %{"id" => ^id} = resp.body
    assert gen(resp.body) == generation
    assert elapsed >= 300
    assert elapsed < @deadline_ms
  end

  test "a foreign owner gets 404 on GET, cancel and long-poll", %{server: server} do
    {id, task} = new_task(server, "ask")
    bob = @v11 ++ [{"x-test-identity", "bob"}]

    get = Req.get!(url: server.base_url <> "/tasks/#{id}", headers: bob, retry: false)
    assert get.status == 404

    poll =
      Req.get!(
        url: server.base_url <> "/tasks/#{id}?currentGeneration=#{gen(task)}",
        headers: bob,
        retry: false
      )

    assert poll.status == 404

    cancel = Req.post!(url: server.base_url <> "/tasks/#{id}:cancel", headers: bob, retry: false)
    assert cancel.status == 404

    # the owner still sees it
    own = Req.get!(url: server.base_url <> "/tasks/#{id}", headers: @v11, retry: false)
    assert own.status == 200
  end

  # -- stream lifetime across paused states ------------------------------------------------

  for {label, text, paused} <- [
        {"input-required", "ask", "TASK_STATE_INPUT_REQUIRED"},
        {"auth-required", "auth", "TASK_STATE_AUTH_REQUIRED"}
      ] do
    test "stream ends at #{label} (paused segment) and a follow-up completes the task", %{
      server: server
    } do
      {ref, sse} =
        open_sse(server.base_url <> "/message:stream", %{"message" => wire(unquote(text))})

      {frames0, _buffer} = collect_until(ref, "", &has_state?(&1, unquote(paused)))
      id = Enum.find_value(frames0, &get_in(&1, ["task", "id"]))
      assert is_binary(id)

      # interrupted state closes this stream segment; the task itself stays live
      assert %Req.Response{status: 200} = Task.await(sse, @deadline_ms)

      follow_up =
        AshA2A.Protocol.JSON.encode!(Message.new_user([Part.Text.new("done")]))
        |> Map.put("taskId", id)

      assert send_message(server, follow_up).status == 200
    end
  end

  # -- blocking send -------------------------------------------------------------------------

  test "blocking send returns at input-required", %{server: server} do
    resp =
      Req.post!(
        url: server.base_url <> "/message:send",
        json: %{"message" => wire("ask"), "configuration" => %{"returnImmediately" => false}},
        headers: @v11,
        retry: false,
        receive_timeout: @deadline_ms
      )

    assert resp.status == 200
    assert %{"task" => %{"status" => %{"state" => "TASK_STATE_INPUT_REQUIRED"}}} = resp.body
  end

  # -- cancel of a completed task ----------------------------------------------------------------

  test "cancel of a completed task is -32002 TASK_NOT_CANCELABLE", %{server: server} do
    {id, task} = new_task(server, "hello")
    assert get_in(task, ["status", "state"]) == "TASK_STATE_COMPLETED"

    assert AshA2A.Protocol.JSONRPC.Error.task_not_cancelable().code == -32_002

    resp = Req.post!(url: server.base_url <> "/tasks/#{id}:cancel", headers: @v11, retry: false)
    assert resp.status == 409
    assert %{"error" => %{"details" => details}} = resp.body
    assert Enum.any?(details, &(&1["reason"] == "TASK_NOT_CANCELABLE"))
  end

  # -- lastChunk -> end_generation ----------------------------------------------------------------

  defp client_update(artifact_id, last_chunk) do
    base = %{
      "artifact" => %{"artifactId" => artifact_id, "parts" => [%{"text" => "x"}]},
      "append" => true
    }

    if is_nil(last_chunk), do: base, else: Map.put(base, "lastChunk", last_chunk)
  end

  defp apply_update(update) do
    {:ok, decoded} = ClientArtifacts.decode_updates([update])
    task = ClientArtifacts.apply_updates(AshA2A.Protocol.Task.new([]), decoded)
    assert [%Artifact{} = artifact] = task.artifacts
    artifact
  end

  test "lastChunk true sets end_generation; false leaves it nil" do
    closed = apply_update(client_update("a-true", true))
    assert is_integer(closed.end_generation)
    assert closed.end_generation == closed.start_generation

    open = apply_update(client_update("a-false", false))
    assert open.end_generation == nil
    assert is_integer(open.start_generation)
  end

  # -- server artifact role --------------------------------------------------------------------------

  test "server-produced artifact role defaults to :agent" do
    {:ok, task} = AshA2A.Protocol.call(Agent, "hello")
    assert [_ | _] = task.artifacts
    # nil is the documented agent-originated default; :user marks client artifacts
    assert Enum.all?(task.artifacts, &(&1.role in [nil, :agent]))
  end
end


# --- SECTION 3: Original test/application_supervision_wiring_test.exs ---
defmodule AshA2A.ApplicationSupervisionWiringTest do
  use ExUnit.Case, async: false

  alias AshA2A.Application, as: App

  setup do
    prev_grpc = Application.fetch_env(:ash_a2a, :grpc)
    prev_server = Application.fetch_env(:ash_a2a, AshA2A.Transport.GRPC.Server)

    on_exit(fn ->
      restore(:grpc, prev_grpc)
      restore(AshA2A.Transport.GRPC.Server, prev_server)
    end)

    :ok
  end

  defp restore(key, {:ok, v}), do: Application.put_env(:ash_a2a, key, v)
  defp restore(key, :error), do: Application.delete_env(:ash_a2a, key)

  test "no grpc config adds no child" do
    Application.delete_env(:ash_a2a, :grpc)
    assert App.grpc_children() == []

    Application.put_env(:ash_a2a, :grpc, port: 0)
    assert App.grpc_children() == []
  end

  test "attach_otel never raises" do
    assert App.attach_otel() in [:ok, {:error, :opentelemetry_not_loaded}] or
             match?({:error, _}, App.attach_otel())
  end

  test "grpc config (keyword and map) yields the supervisor child" do
    Application.put_env(:ash_a2a, :grpc, port: 0, handler: __MODULE__)
    assert [{AshA2A.Transport.GRPC.Supervisor, opts}] = App.grpc_children()
    assert opts[:port] == 0

    Application.put_env(:ash_a2a, :grpc, %{port: 0, handler: __MODULE__})
    assert [{AshA2A.Transport.GRPC.Supervisor, opts}] = App.grpc_children()
    assert opts[:handler] == __MODULE__
  end

  test "child starts under an isolated supervisor on an ephemeral port" do
    name = :"w22_grpc_#{System.unique_integer([:positive])}"
    Application.put_env(:ash_a2a, :grpc, port: 0, handler: __MODULE__, name: name)

    [child] = App.grpc_children()
    {:ok, sup} = Supervisor.start_link([child], strategy: :one_for_one)

    port = AshA2A.Transport.GRPC.Supervisor.port(name)
    assert is_integer(port) and port > 0

    Supervisor.stop(sup)
    refute Process.whereis(name)
  end
end


# --- SECTION 4: Original test/artifact_only_generation_guard_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ArtifactOnlyGenerationGuardTest do
  @moduledoc """
  X1 court: an artifact-only `message:send` honours `ifGenerationMatch`
  atomically. The agent GenServer rechecks the generation inside its
  serialized handler, so two concurrent writers holding the same generation
  cannot both succeed. Real agent GenServer, real HTTP+JSON plug; no mocks.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Transport.HTTPJSON

  defmodule Agent do
    use AshA2A.Protocol.Agent,
      name: "x1-open",
      description: "accepts client artifacts",
      capabilities: %{user_artifacts: true}

    @impl AshA2A.Protocol.Agent
    def handle_message(message, _ctx) do
      case AshA2A.Protocol.Message.text(message) do
        "ask" -> {:input_required, [AshA2A.Protocol.Part.Text.new("more?")]}
        _ -> {:reply, [AshA2A.Protocol.Part.Text.new("ok")]}
      end
    end
  end

  setup do
    start_supervised!({Agent, []})

    versions = Enum.uniq(AshA2A.Protocol.Version.supported_default() ++ ["1.0", "1.1"])
    opts = HTTPJSON.init(agent: Agent, base_url: "http://127.0.0.1/x1", versions: versions)
    {:ok, opts: opts}
  end

  defp post(opts, path, body) do
    conn =
      :post
      |> Plug.Test.conn(path, Jason.encode!(body))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("a2a-version", "1.1")
      |> AshA2A.Protocol.Plug.Auth.put_identity(%{identity: "alice"})
      |> HTTPJSON.call(opts)

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp new_task(opts) do
    message = %{
      "messageId" => "m-#{System.unique_integer([:positive])}",
      "role" => "ROLE_USER",
      "parts" => [%{"text" => "ask"}]
    }

    {200, %{"task" => task}} = post(opts, "/message:send", %{"message" => message})
    {task["id"], gen(task)}
  end

  defp gen(%{"generation" => g}) do
    {n, ""} = g |> to_string() |> Integer.parse()
    n
  end

  defp artifact_only(opts, id, expected) do
    artifact = %{
      "artifactId" => "a-#{System.unique_integer([:positive])}",
      "parts" => [%{"text" => "x"}]
    }

    post(opts, "/message:send", %{
      "artifactUpdates" => [%{"taskId" => id, "artifact" => artifact}],
      "configuration" => %{"ifGenerationMatch" => expected}
    })
  end

  test "stale ifGenerationMatch on an artifact-only send is 409 TASK_GENERATION_MISMATCH", %{
    opts: opts
  } do
    {id, generation} = new_task(opts)

    assert {409, %{"error" => %{"details" => details}}} = artifact_only(opts, id, generation + 5)
    assert Enum.any?(details, &(&1["reason"] == "TASK_GENERATION_MISMATCH"))

    # State unchanged: the refused write did not advance the generation.
    assert {:ok, task} = GenServer.call(Agent, {:get_task, id})
    assert AshA2A.Protocol.Task.Generation.generation_of(task) == generation
  end

  test "agent handler itself refuses a stale generation (-32010 source of truth)" do
    # Bypasses the HTTP pre-check entirely: the GenServer is the authority.
    opts = HTTPJSON.init(agent: Agent, base_url: "http://127.0.0.1/x1", versions: ["1.0", "1.1"])
    {id, generation} = new_task(opts)

    {:ok, decoded} =
      AshA2A.Protocol.ClientArtifacts.decode_updates([
        %{
          "taskId" => id,
          "artifact" => %{"artifactId" => "direct", "parts" => [%{"text" => "x"}]}
        }
      ])

    assert {:error, :generation_mismatch} =
             GenServer.call(Agent, {:apply_artifact_updates, id, decoded, generation + 5})

    assert {:ok, _task} =
             GenServer.call(Agent, {:apply_artifact_updates, id, decoded, generation})
  end

  test "matching ifGenerationMatch on an artifact-only send proceeds and advances generation", %{
    opts: opts
  } do
    {id, generation} = new_task(opts)

    assert {200, body} = artifact_only(opts, id, generation)
    task = body["task"] || body
    assert task["id"] == id
    assert gen(task) > generation
  end

  test "two concurrent artifact-only sends with the same ifGenerationMatch yield exactly one success",
       %{opts: opts} do
    for _round <- 1..10 do
      {id, generation} = new_task(opts)

      results =
        1..2
        |> Enum.map(fn _ -> Task.async(fn -> artifact_only(opts, id, generation) end) end)
        |> Task.await_many(5_000)

      statuses = results |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      assert statuses == [200, 409]
    end
  end
end


# --- SECTION 5: Original test/ash_a2a_a2a_methods_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2AA2AMethodsTest do
  @moduledoc """
  Per-method JSON-RPC conformance over the real `AshA2A.Protocol.Plug` fronting a real
  `AshA2A.Agent` GenServer (no mocks; real `Plug.Test` conns). Each test
  asserts the observed wire response of ONE A2A method. Methods the vendored
  `:a2a` Plug does not implement are asserted as the typed refusal it really
  returns (`-32004` unsupported operation), never as success.

  See `docs/reference/a2a-spec-version-mapping.md`.
  """
  use ExUnit.Case, async: true

  alias AshA2A.Test.PlugFixture.GreeterAgent

  setup do
    name = :"a2a_methods_agent_#{System.unique_integer([:positive])}"
    {:ok, pid} = GreeterAgent.start_link(name: name)
    on_exit(fn -> AshA2A.TestSupport.SafeStop.stop(pid) end)

    %{
      agent: name,
      plug_opts: AshA2A.Protocol.Plug.init(agent: name, base_url: "http://localhost:4000/a2a")
    }
  end

  defp rpc(plug_opts, method, params) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => method,
        "params" => params
      })

    :post
    |> Plug.Test.conn("/", body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> AshA2A.Protocol.Plug.call(plug_opts)
  end

  defp message do
    {:ok, encoded} = AshA2A.Protocol.JSON.encode(AshA2A.Protocol.Message.new_user("hello"))
    encoded
  end

  test "message/send returns a task result", %{plug_opts: o} do
    conn = rpc(o, "message/send", %{"message" => message()})
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    # v1.0: the send result is the StreamResponse {"task": ...} wrapper; the
    # wrapped task carries no "kind" discriminator and flat {"text": ...}
    # parts.
    assert %{"result" => %{"task" => %{"id" => id} = task_json}} = body
    refute Map.has_key?(task_json, "kind")
    assert is_binary(id)
  end

  test "tasks/get returns the task created by message/send", %{plug_opts: o} do
    %{"result" => %{"task" => %{"id" => id}}} =
      o
      |> rpc("message/send", %{"message" => message()})
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()

    body = o |> rpc("tasks/get", %{"id" => id}) |> Map.fetch!(:resp_body) |> Jason.decode!()
    assert %{"result" => %{"id" => ^id}} = body
  end

  test "tasks/get on an unknown id is -32001 task not found", %{plug_opts: o} do
    body = o |> rpc("tasks/get", %{"id" => "nope"}) |> Map.fetch!(:resp_body) |> Jason.decode!()
    assert %{"error" => %{"code" => -32001}} = body
  end

  test "tasks/cancel on an unknown id is -32001 task not found", %{plug_opts: o} do
    body =
      o |> rpc("tasks/cancel", %{"id" => "nope"}) |> Map.fetch!(:resp_body) |> Jason.decode!()

    assert %{"error" => %{"code" => -32001}} = body
  end

  test "tasks/cancel on a completed task is refused (not cancelable)", %{plug_opts: o} do
    %{"result" => %{"task" => %{"id" => id}}} =
      o
      |> rpc("message/send", %{"message" => message()})
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()

    body = o |> rpc("tasks/cancel", %{"id" => id}) |> Map.fetch!(:resp_body) |> Jason.decode!()
    assert %{"error" => %{"code" => -32002}} = body
  end

  test "tasks/resubscribe is the vendored plug's typed unsupported-operation refusal", %{
    plug_opts: o
  } do
    body =
      o |> rpc("tasks/resubscribe", %{"id" => "x"}) |> Map.fetch!(:resp_body) |> Jason.decode!()

    assert %{"error" => %{"code" => -32004}} = body
  end

  test "agent/getAuthenticatedExtendedCard is the typed not-configured refusal (-32007)", %{
    plug_opts: o
  } do
    body =
      o
      |> rpc("agent/getAuthenticatedExtendedCard", %{})
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()

    assert %{"error" => %{"code" => -32007}} = body
  end

  # TQ-05: the vendored `AshA2A.Protocol.Plug` answers `message/stream` for a
  # non-streaming skill with a `{:not_streaming, task}` JSON-RPC error, because
  # `AshA2A.Protocol.stream/3` only accepts a `{:stream, enum}` handler reply. ash_a2a's
  # own transport (`AshA2A.Transport.Plug`) streams every reply: the task
  # snapshot, one `artifact-update` per artifact, and a final status. This
  # test drives the same GreeterAgent through that transport; the raw-plug
  # behavior is pinned separately below so the difference stays visible.
  test "message/stream answers with an SSE event stream (AshA2A.Transport.Plug)", %{
    agent: agent
  } do
    opts = AshA2A.Transport.Plug.init(agent: agent, base_url: "http://localhost:4000/a2a")

    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "message/stream",
        "params" => %{"message" => message()}
      })

    conn =
      :post
      |> Plug.Test.conn("/", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> AshA2A.Transport.Plug.call(opts)

    assert [ct] = Plug.Conn.get_resp_header(conn, "content-type")
    assert ct =~ "text/event-stream"
    assert conn.resp_body =~ "data: "

    events =
      conn.resp_body
      |> String.split("\n\n", trim: true)
      |> Enum.map(fn "data: " <> json -> Jason.decode!(json)["result"] end)

    # v1.0 StreamResponse wire contract: every frame's `result` is wrapped as
    # exactly one {"task" | "statusUpdate" | "artifactUpdate" => ...} key — the
    # wrapper key is the discriminator; there is no "kind" and no "final"
    # boolean anywhere (finality is the last event's terminal TASK_STATE_*).
    assert events != []

    assert Enum.all?(events, fn event ->
             map_size(event) == 1 and
               (Map.has_key?(event, "task") or Map.has_key?(event, "statusUpdate") or
                  Map.has_key?(event, "artifactUpdate"))
           end)

    refute Enum.any?(events, fn
             %{"statusUpdate" => inner} -> Map.has_key?(inner, "final")
             _event -> false
           end)

    # Finality: the stream closes on the last event's terminal TASK_STATE_*;
    # the last frame is a statusUpdate carrying a terminal state.
    assert %{"statusUpdate" => %{"status" => %{"state" => state}}} = List.last(events)
    assert state in ["TASK_STATE_COMPLETED", "TASK_STATE_FAILED", "TASK_STATE_CANCELED"]
  end

  test "raw AshA2A.Protocol.Plug message/stream on a non-streaming skill is the vendored JSON error",
       %{plug_opts: o} do
    conn = rpc(o, "message/stream", %{"message" => message()})
    assert [ct] = Plug.Conn.get_resp_header(conn, "content-type")
    assert ct =~ "application/json"
    # 0.3 wire contract: a non-streaming skill rejects `message/stream` with
    # the typed -32004 UNSUPPORTED_OPERATION error (google.rpc.ErrorInfo data).
    assert %{"error" => %{"code" => -32004}} = Jason.decode!(conn.resp_body)
  end

  test "unknown method is -32601", %{plug_opts: o} do
    body = o |> rpc("no/such", %{}) |> Map.fetch!(:resp_body) |> Jason.decode!()
    assert %{"error" => %{"code" => -32601}} = body
  end
end


# --- SECTION 6: Original test/ash_a2a_actuation_identity_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ActuationIdentityTest do
  @moduledoc """
  RFC-SA2A-001 S55 replay protection.

  Two real stores are exercised against the same claim: the real
  `AshA2A.ReceiptStore.Memory` GenServer, and a real on-disk `EKV` instance
  via `AshA2A.ReceiptStore.Ekv` (same `cluster_size: 1` real-local-EKV setup
  `test/ash_a2a/receipt_store_ekv_test.exs` already uses). The consequence
  being protected is a real counter increment in
  `AshA2A.Test.Fixture.CountingActuator`, so "the effect did not repeat" is a
  state assertion on a real integer, not an interaction assertion.
  """
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Actuation, Command, CommandBus, Identity}
  alias AshA2A.ReceiptStore.Ekv
  alias AshA2A.Test.Fixture.{KeyedActuationCounter, CountingActuator}

  @capability "AshA2A.Test.Fixture.CountingActuator.actuate"

  setup do
    Application.put_env(:ash_a2a, :receipt_commit_retry_delays_ms, [1, 1])
    on_exit(fn -> Application.delete_env(:ash_a2a, :receipt_commit_retry_delays_ms) end)

    start_supervised!(KeyedActuationCounter)

    memory = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: memory})

    %{store_opts: [name: memory]}
  end

  defp command(command_id, effect_key, opts \\ []) do
    principal = Identity.principal(Keyword.get(opts, :principal, "s55-principal"))

    authority =
      AshA2A.Authority.new(principal, @capability,
        token_id: "s55-auth",
        constraints: Keyword.get(opts, :constraints, %{})
      )

    Command.new(@capability,
      command_id: command_id,
      agent_id: Keyword.get(opts, :agent_id, "s55-agent"),
      principal_id: principal,
      authority: authority,
      input: %{effect_key: effect_key},
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  defp run(command, effect_key, store_opts, extra \\ []) do
    CommandBus.run(
      command,
      data_message(%{"effect_key" => effect_key}),
      CountingActuator,
      Keyword.merge([store_opts: store_opts], extra)
    )
  end

  # --- derivation ---------------------------------------------------------

  test "actuation identity is derived from the effect, not from the request id or agent" do
    key = "derive-#{System.unique_integer([:positive])}"

    one = command("cmd-a", key, agent_id: "agent-one")
    two = command("cmd-b", key, agent_id: "agent-two")

    a = Actuation.identity(one)
    b = Actuation.identity(two)

    assert a.actuation_id == b.actuation_id
    assert %Identity{kind: :actuation} = a.actuation_id
    assert a.effect_digest == b.effect_digest

    # A different input is a different effect.
    other = command("cmd-c", "a-different-effect-key")
    refute Actuation.identity(other).actuation_id == a.actuation_id

    # A different principal is a different effect.
    other_principal = command("cmd-d", key, principal: "someone-else")
    refute Actuation.identity(other_principal).actuation_id == a.actuation_id
  end

  test "the idempotency identity binds to the external token when one is supplied" do
    key = "bind-#{System.unique_integer([:positive])}"

    from_metadata = command("cmd-meta", key, metadata: %{idempotency_key: "ext_tok_meta"})
    assert Actuation.identity(from_metadata).idempotency_key.value == "ext_tok_meta"
    assert Actuation.identity(from_metadata).external_token?

    from_string_key = command("cmd-str", key, metadata: %{"idempotency_key" => "ext_tok_str"})
    assert Actuation.identity(from_string_key).idempotency_key.value == "ext_tok_str"

    from_constraints =
      command("cmd-cons", key, constraints: %{external_idempotency_token: "ext_tok_cons"})

    assert Actuation.identity(from_constraints).idempotency_key.value == "ext_tok_cons"

    from_opts = Actuation.identity(command("cmd-opt", key), idempotency_key: "ext_tok_opt")
    assert from_opts.idempotency_key.value == "ext_tok_opt"

    # With no external token the key is still STABLE -- derived from the same
    # effect tuple -- just not shared with any external system.
    plain = command("cmd-plain", key)
    refute Actuation.identity(plain).external_token?

    assert Actuation.identity(plain).idempotency_key ==
             Actuation.identity(command("cmd-plain-retry", key)).idempotency_key
  end

  test "derivation is pure: the same command yields the same pair on every call and process" do
    cmd = command("pure-1", "pure-effect")
    here = Actuation.identity(cmd)
    there = Task.await(Task.async(fn -> Actuation.identity(cmd) end))

    assert here == there
  end

  # --- enforcement against the real Memory store --------------------------

  test "a client retry under a FRESH command id does not repeat the effect (Memory store, :strict)",
       %{store_opts: store_opts} do
    key = "memory-dedup-#{System.unique_integer([:positive])}"
    strict = [actuation_dedup: :strict]

    assert {:ok, first} = run(command("retry-original", key), key, store_opts, strict)
    assert first.terminal_status == :executed
    assert KeyedActuationCounter.count(key) == 1

    # The accident S55 exists for: same effect, brand new command id. The
    # command-id claim cannot see it; the actuation claim can.
    assert {:ok, second} = run(command("retry-fresh-id", key), key, store_opts, strict)

    assert KeyedActuationCounter.count(key) == 1
    assert second.replayed?
    assert second.metadata.outcome == :deduplicated
    assert second.metadata.deduplicated_from_receipt_id == Identity.external(first.receipt_id)
    assert second.metadata.deduplicated_from_command_id == Identity.external(first.command_id)
    assert second.terminal_status == first.terminal_status

    # The dedup receipt is its own receipt for the NEW command id -- it closes
    # that claim rather than leaving it dangling at `receipt: nil`.
    assert second.command_id == Identity.command("retry-fresh-id")

    assert {:ok, fetched} =
             AshA2A.ReceiptStore.Memory.fetch(Identity.command("retry-fresh-id"), store_opts)

    assert fetched.receipt_id == second.receipt_id

    # Ten more fresh-id retries; the real counter still reads 1.
    for n <- 1..10 do
      assert {:ok, _} = run(command("retry-fresh-#{n}", key), key, store_opts, strict)
    end

    assert KeyedActuationCounter.count(key) == 1
  end

  test "the DEFAULT mode is :strict (RFC-SA2A-004 S11): a fresh-id repeat of the same effect is refused a second crossing",
       %{store_opts: store_opts} do
    key = "default-strict-#{System.unique_integer([:positive])}"

    assert CommandBus.actuation_dedup_mode() == :strict

    assert {:ok, first} = run(command("strict-1", key), key, store_opts)
    assert {:ok, second} = run(command("strict-2", key), key, store_opts)

    assert KeyedActuationCounter.count(key) == 1
    assert first.actuation_id == second.actuation_id
    assert second.metadata.outcome == :deduplicated
    refute Map.has_key?(first.intended_effect, :actuation_dedup_compat)
  end

  test "explicit :declared is a LEGACY opt-in: undeclared repeat executes and receipts stamp compat",
       %{store_opts: store_opts} do
    key = "declared-#{System.unique_integer([:positive])}"
    legacy = [actuation_dedup: :declared]

    assert {:ok, first} = run(command("declared-1", key), key, store_opts, legacy)
    assert {:ok, second} = run(command("declared-2", key), key, store_opts, legacy)

    # Both really executed: legacy semantics withhold enforcement without a
    # client-declared key. The identities are still derived and recorded, and
    # the receipts say the legacy compatibility mode was in force.
    assert KeyedActuationCounter.count(key) == 2
    assert first.actuation_id == second.actuation_id
    assert first.idempotency_key == second.idempotency_key
    refute second.metadata[:outcome] == :deduplicated
    assert first.intended_effect.actuation_dedup_compat == :declared_legacy
    assert second.intended_effect.actuation_dedup_compat == :declared_legacy

    declared = command("declared-3", key, metadata: %{idempotency_key: "declared_token"})
    assert {:ok, _} = run(declared, key, store_opts, legacy)
    assert KeyedActuationCounter.count(key) == 3

    declared_retry = command("declared-4", key, metadata: %{idempotency_key: "declared_token"})
    assert {:ok, dedup} = run(declared_retry, key, store_opts, legacy)
    assert KeyedActuationCounter.count(key) == 3
    assert dedup.metadata.outcome == :deduplicated
  end

  test "an external idempotency token makes two textually different commands one effect", %{
    store_opts: store_opts
  } do
    key_a = "tok-a-#{System.unique_integer([:positive])}"

    first = command("tok-1", key_a, metadata: %{idempotency_key: "shared_ext_token"})
    assert {:ok, _} = run(first, key_a, store_opts)
    assert KeyedActuationCounter.count(key_a) == 1

    # Same effect content AND the same external token: one actuation.
    second = command("tok-2", key_a, metadata: %{idempotency_key: "shared_ext_token"})
    assert {:ok, receipt} = run(second, key_a, store_opts)

    assert KeyedActuationCounter.count(key_a) == 1
    assert receipt.metadata.outcome == :deduplicated
    assert receipt.idempotency_key.value == "shared_ext_token"
  end

  test "a genuinely different effect is NOT deduplicated", %{store_opts: store_opts} do
    key_one = "distinct-one-#{System.unique_integer([:positive])}"
    key_two = "distinct-two-#{System.unique_integer([:positive])}"

    strict = [actuation_dedup: :strict]
    assert {:ok, one} = run(command("distinct-1", key_one), key_one, store_opts, strict)
    assert {:ok, two} = run(command("distinct-2", key_two), key_two, store_opts, strict)

    assert KeyedActuationCounter.count(key_one) == 1
    assert KeyedActuationCounter.count(key_two) == 1
    refute two.metadata[:outcome] == :deduplicated
    refute one.actuation_id == two.actuation_id
  end

  test "observe commands are never actuation-claimed -- reading twice is not an effect", %{
    store_opts: store_opts
  } do
    one =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "observe-a",
        agent_id: "s55-agent",
        principal_id: "anonymous",
        input: %{}
      )

    two =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "observe-b",
        agent_id: "s55-agent",
        principal_id: "anonymous",
        input: %{}
      )

    # Identical effect tuples...
    assert Actuation.identity(one).actuation_id == Actuation.identity(two).actuation_id

    # ...but both really execute, because there is no consequence to protect.
    assert {:ok, first} =
             CommandBus.run(one, data_message(%{}), AshA2A.Test.Fixture.Echo,
               store_opts: store_opts
             )

    assert {:ok, second} =
             CommandBus.run(two, data_message(%{}), AshA2A.Test.Fixture.Echo,
               store_opts: store_opts
             )

    refute second.metadata[:outcome] == :deduplicated
    refute first.receipt_id == second.receipt_id
    # The identities are still RECORDED on observe receipts, just not enforced.
    assert first.actuation_id
    assert first.idempotency_key
  end

  test "an in-flight actuation refuses a concurrent second claimant instead of double-actuating",
       %{store_opts: store_opts} do
    key = "inflight-#{System.unique_integer([:positive])}"
    cmd = command("inflight-1", key)
    actuation = Actuation.identity(cmd)

    # Claim the actuation directly against the real store and never commit it
    # -- exactly the state a crashed-mid-execution claimant leaves behind.
    assert :proceed = AshA2A.ReceiptStore.Memory.claim_actuation(actuation, cmd, store_opts)

    assert {:error, %{code: :actuation_in_flight, receipt: receipt}} =
             run(command("inflight-2", key), key, store_opts, actuation_dedup: :strict)

    assert KeyedActuationCounter.count(key) == 0
    assert receipt.terminal_status == :refused
    assert receipt.status == :failed

    # Releasing the unexecuted claim reopens the effect -- a crashed claimant
    # must not wedge it forever.
    assert :ok = AshA2A.ReceiptStore.Memory.release_actuation(actuation, store_opts)
    assert {:ok, _} = run(command("inflight-3", key), key, store_opts, actuation_dedup: :strict)
    assert KeyedActuationCounter.count(key) == 1
  end

  test "release_actuation refuses to reopen an already-executed effect", %{store_opts: store_opts} do
    key = "no-reopen-#{System.unique_integer([:positive])}"
    cmd = command("no-reopen-1", key)

    assert {:ok, _} = run(cmd, key, store_opts, actuation_dedup: :strict)
    assert KeyedActuationCounter.count(key) == 1

    # Releasing a COMMITTED actuation is a no-op: it must not become a way to
    # launder a second execution.
    assert :ok = AshA2A.ReceiptStore.Memory.release_actuation(Actuation.identity(cmd), store_opts)

    assert {:ok, receipt} =
             run(command("no-reopen-2", key), key, store_opts, actuation_dedup: :strict)

    assert KeyedActuationCounter.count(key) == 1
    assert receipt.metadata.outcome == :deduplicated
  end

  # --- enforcement against the real on-disk EKV store ---------------------

  describe "real on-disk EKV store" do
    setup do
      ekv_name = :"ash_a2a_s55_ekv_#{System.unique_integer([:positive])}"

      data_dir =
        Path.join(System.tmp_dir!(), "ash_a2a_s55_ekv_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(data_dir) end)
      start_supervised!({EKV, name: ekv_name, data_dir: data_dir, cluster_size: 1})

      %{ekv_opts: [name: ekv_name]}
    end

    test "a fresh-command-id retry is deduplicated by the durable actuation index", %{
      ekv_opts: ekv_opts
    } do
      key = "ekv-dedup-#{System.unique_integer([:positive])}"

      assert {:ok, first} =
               run(command("ekv-1", key), key, ekv_opts, store: Ekv, actuation_dedup: :strict)

      assert first.standing == :durable
      assert KeyedActuationCounter.count(key) == 1

      assert {:ok, second} =
               run(command("ekv-2-fresh-id", key), key, ekv_opts,
                 store: Ekv,
                 actuation_dedup: :strict
               )

      assert KeyedActuationCounter.count(key) == 1
      assert second.metadata.outcome == :deduplicated
      assert second.metadata.deduplicated_from_command_id == Identity.external(first.command_id)
    end

    test "the actuation claim survives in EKV and refuses an in-flight second claimant", %{
      ekv_opts: ekv_opts
    } do
      key = "ekv-inflight-#{System.unique_integer([:positive])}"
      cmd = command("ekv-inflight-1", key)
      actuation = Actuation.identity(cmd)

      assert :proceed = Ekv.claim_actuation(actuation, cmd, ekv_opts)
      assert {:error, :actuation_in_flight} = Ekv.claim_actuation(actuation, cmd, ekv_opts)

      assert {:error, %{code: :actuation_in_flight}} =
               run(command("ekv-inflight-2", key), key, ekv_opts,
                 store: Ekv,
                 actuation_dedup: :strict
               )

      assert KeyedActuationCounter.count(key) == 0

      assert :ok = Ekv.release_actuation(actuation, ekv_opts)

      assert {:ok, _} =
               run(command("ekv-inflight-3", key), key, ekv_opts,
                 store: Ekv,
                 actuation_dedup: :strict
               )

      assert KeyedActuationCounter.count(key) == 1
    end

    test "two callers disagreeing about the external token for one effect is a conflict", %{
      ekv_opts: ekv_opts
    } do
      key = "ekv-conflict-#{System.unique_integer([:positive])}"

      first = command("ekv-conf-1", key, metadata: %{idempotency_key: "token_one"})
      second = command("ekv-conf-2", key, metadata: %{idempotency_key: "token_two"})

      # Different external tokens change the effect digest too, so these are
      # different actuations -- the honest outcome, and both really execute.
      assert {:ok, _} = run(first, key, ekv_opts, store: Ekv)
      assert {:ok, _} = run(second, key, ekv_opts, store: Ekv)
      assert KeyedActuationCounter.count(key) == 2

      # A true conflict is the same actuation id held under a different
      # idempotency key, which the store detects directly.
      a = Actuation.identity(first)
      forged = %{a | idempotency_key: Identity.idempotency("a_completely_different_token")}

      assert {:error, :actuation_conflict} = Ekv.claim_actuation(forged, first, ekv_opts)
    end
  end
end


# --- SECTION 7: Original test/ash_a2a_agent_command_bus_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT







# --- SECTION 8: Original test/ash_a2a_agent_moduledoc_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2AAgentModuledocTest do
  @moduledoc """
  Chicago-style test for the `AshA2A.Agent` concurrency-caveat documentation
  fix (Zach-Daniel-review finding: concurrent dispatch to one agent is fully
  serialized through a single GenServer mailbox, so a slow in-flight
  `:message` call blocks `get_task`/`cancel` for every other in-flight task
  on that agent instance).

  Asserts on the real, compiled `@moduledoc` content fetched via
  `Code.fetch_docs/1` against the actual `AshA2A.Agent` module on disk -- no
  Mock/mox/patch, no hand-built string fixture standing in for the module.
  """

  use ExUnit.Case

  test "AshA2A.Agent's real compiled moduledoc documents off-mailbox async execution and the inline escape hatch" do
    assert {:docs_v1, _anno, :elixir, _format, %{"en" => moduledoc}, _meta, _docs} =
             Code.fetch_docs(AshA2A.Agent)

    # Superseded the single-mailbox caveat: handlers now run in monitored
    # workers (AshA2A.Transport.Runtime); `mode: :inline` restores serialization.
    assert moduledoc =~ "no longer runs handlers inside its own mailbox"
    assert moduledoc =~ "mode: :async"
    assert moduledoc =~ "mode: :inline"
    assert moduledoc =~ "max_in_flight"
  end
end


# --- SECTION 9: Original test/ash_a2a_agent_multi_turn_carry_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2AAgentMultiTurnCarryTest do
  @moduledoc """
  Real multi-turn argument carry-over through a real supervised `AshA2A.Protocol.Agent`:
  turn 1's Data arguments survive into turn 2's dispatch. No mocks.
  """

  use ExUnit.Case, async: true

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.Fixture.MultiTurnPairAgent

  setup do
    AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [MultiTurnPairAgent])
    :ok
  end

  test "a follow-up supplying only the missing argument completes with turn 1's argument" do
    assert {:ok, turn1} = MultiTurnPairAgent.call(MultiTurnPairAgent, data_message(%{left: "a"}))
    assert turn1.status.state == :input_required

    assert {:ok, turn2} =
             MultiTurnPairAgent.call(MultiTurnPairAgent, data_message(%{right: "b"}),
               task_id: turn1.id
             )

    assert turn2.status.state == :completed

    assert [%AshA2A.Protocol.Artifact{parts: [%AshA2A.Protocol.Part.Data{data: result}]}] =
             turn2.artifacts

    assert result[:left] == "a"
    assert result[:right] == "b"
  end

  test "the current turn wins on key collision" do
    assert {:ok, turn1} =
             MultiTurnPairAgent.call(MultiTurnPairAgent, data_message(%{left: "old"}))

    assert turn1.status.state == :input_required

    assert {:ok, turn2} =
             MultiTurnPairAgent.call(
               MultiTurnPairAgent,
               data_message(%{left: "new", right: "r"}),
               task_id: turn1.id
             )

    assert [%AshA2A.Protocol.Artifact{parts: [%AshA2A.Protocol.Part.Data{data: result}]}] =
             turn2.artifacts

    assert result[:left] == "new"
  end

  test "a fresh task with no history is not affected by other tasks" do
    assert {:ok, _} = MultiTurnPairAgent.call(MultiTurnPairAgent, data_message(%{left: "a"}))
    assert {:ok, fresh} = MultiTurnPairAgent.call(MultiTurnPairAgent, data_message(%{right: "b"}))
    assert fresh.status.state == :input_required
  end
end


# --- SECTION 10: Original test/ash_a2a_agent_multi_turn_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2AAgentMultiTurnTest do
  @moduledoc """
  Real multi-turn `task_id:` continuation through a real `AshA2A.Protocol.Agent`
  GenServer process (not a bare `AshA2A.Dispatcher.dispatch/5` call, and not
  just an assertion on the paused task struct's shape).

  This is the one genuinely-untested surface from item #1 of this session's
  research: every existing `{:input_required, _}` test in this suite
  (`test/ash_a2a_dispatcher_*_test.exs`) proves only the *first* turn --
  that a missing-argument `Ash.Error.Invalid` maps to `{:input_required, _}`
  -- and stops there. None of them sends a real follow-up `AshA2A.Protocol.Message` back
  through `AshA2A.Protocol.Agent.call/3` with `task_id:` set to prove the paused task
  actually resumes, nor that `AshA2A.Protocol.Agent.Runtime`'s real accumulated
  `history` genuinely reaches `AshA2A.Dispatcher`'s
  `context[:a2a_history]` on the second turn.

  Chicago-style throughout: a real supervised `AshA2A.Protocol.Agent` process
  (`AshA2A.Test.Fixture.MultiTurnConversationAgent`), real `AshA2A.Protocol.Agent.call/3`
  calls, real state-based assertions on the real returned `AshA2A.Protocol.Task.t()` and
  on real values the fixture's own Ash action computed from real
  `input.context[:a2a_history]` -- no Mock/mox/patch/monkeypatch.
  """

  use ExUnit.Case, async: true

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.Fixture.MultiTurnConversationAgent

  setup do
    {_sup, _registry_name} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [
        MultiTurnConversationAgent
      ])

    :ok
  end

  test "a paused :input_required task resumes under the same real task_id and sees real prior history" do
    # Turn 1: omit the required `:text` argument. `Ash.ActionInput.for_action/3`
    # raises a real `Ash.Error.Invalid` (missing argument), which
    # `AshA2A.Dispatcher.to_reply/1` maps to a real `{:input_required, _}`
    # reply -- pausing the real task under a real `AshA2A.Protocol.Agent`-assigned
    # `task_id`.
    assert {:ok, turn1} =
             MultiTurnConversationAgent.call(MultiTurnConversationAgent, data_message(%{}))

    assert turn1.status.state == :input_required
    assert is_binary(turn1.id)
    task_id = turn1.id

    # The paused task's real history already carries the real inbound user
    # message from turn 1 (AshA2A.Protocol.Agent.Runtime's own bookkeeping, not this
    # test's).
    assert Enum.any?(turn1.history, &(&1.role == :user))

    # Turn 2: continue the SAME real task_id, this time supplying `:text`.
    # This is the actual multi-turn continuation this item targets -- a real
    # follow-up `AshA2A.Protocol.Agent.call/3` naming the paused task, not a fresh call.
    assert {:ok, turn2} =
             MultiTurnConversationAgent.call(
               MultiTurnConversationAgent,
               data_message(%{text: "second turn"}),
               task_id: task_id
             )

    # Same real task, real state machine, now resolved.
    assert turn2.id == task_id
    assert turn2.status.state == :completed

    assert [%AshA2A.Protocol.Artifact{parts: [%AshA2A.Protocol.Part.Data{data: result}]}] =
             turn2.artifacts

    # The fixture's real Ash action itself counted
    # `length(input.context[:a2a_history])` on this second, real dispatch --
    # proof (produced by real Ash action code, not asserted from outside)
    # that the real turn-1 history (the original user message, plus the
    # real `:input_required` agent reply `AshA2A.Protocol.Agent.Runtime` appended) was
    # genuinely threaded into this second call's Ash `context:` opt, not
    # just present on the task struct this test can already see directly.
    assert result[:text] == "second turn"
    assert result[:prior_turns] >= 1

    # The real accumulated history on the resumed task also includes both
    # real turns end to end.
    assert Enum.count(turn2.history, &(&1.role == :user)) == 2

    # Getting the task back out by id proves it's genuinely the same
    # real, persisted task -- not a same-shaped new one.
    assert {:ok, fetched} =
             MultiTurnConversationAgent.get_task(MultiTurnConversationAgent, task_id)

    assert fetched.id == task_id
    assert fetched.status.state == :completed
  end
end


# --- SECTION 11: Original test/ash_a2a_agent_semantic_replan_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT









# --- SECTION 12: Original test/ash_a2a_agent_semantic_request_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Test.Fixture.SemanticEnabled.Resource do
  @moduledoc """
  Real fixture resource, private to this test file: a single real `:read`
  skill (so the ordinary skill-resolution fallback path is exercisable
  without ambiguity) plus `a2a do semantic_requests true end`, explicitly
  opting this resource into the semantic-compilation A2A surface.
  """

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.SemanticEnabled.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])
  end

  a2a do
    semantic_requests(true)
    skill(:probe, :read)
  end
end

defmodule AshA2A.Test.Fixture.SemanticEnabled.Domain do
  @moduledoc "Real fixture domain for `SemanticEnabled.Resource` above."

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.Test.Fixture.SemanticEnabled.Resource)
  end
end

defmodule AshA2A.Test.Fixture.SemanticEnabledAgent do
  @moduledoc "Real `AshA2A.Protocol.Agent` GenServer over `SemanticEnabled.Resource` above."

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.SemanticEnabled.Resource,
    name: "semantic_enabled_agent"
end

defmodule AshA2AAgentSemanticRequestTest do
  @moduledoc """
  Proves the v26.9.14 explicit semantic-compilation A2A surface's two real
  gates -- both must be true before any real dispatch reaches
  `AshA2A.Semantic.Compiler.compile/3` -- and that a genuinely-gated request
  fails closed with a real, typed error rather than crashing the real
  `AshA2A.Protocol.Agent` process when the required LLM profile is unconfigured (the
  real, unmodified test environment has no `:semantic_reasoner` profile
  configured). No Mock/mox/patch/monkeypatch anywhere in this file; every
  assertion is against real dispatch through a real supervised `AshA2A.Protocol.Agent`
  process.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.Fixture.{Echo, EchoAgent, SemanticEnabledAgent}

  setup do
    {_sup, _registry_name} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [
        SemanticEnabledAgent,
        EchoAgent
      ])

    :ok
  end

  test "AshA2A.Info.semantic_requests_enabled?/1 reflects the real compiled DSL declaration" do
    assert AshA2A.Info.semantic_requests_enabled?(AshA2A.Test.Fixture.SemanticEnabled.Resource)

    refute AshA2A.Info.semantic_requests_enabled?(Echo)
  end

  test "gate 1: resource opted in, but the message carries no semantic_request flag -- falls through to ordinary skill dispatch" do
    # No `:semantic_request` metadata at all -- the single real `:probe`
    # `:read` skill resolves via the ordinary default-skill path.
    assert {:ok, task} = SemanticEnabledAgent.call(SemanticEnabledAgent, data_message(%{}))
    assert task.status.state == :completed
    assert [%AshA2A.Protocol.Artifact{parts: [%AshA2A.Protocol.Part.Data{}]}] = task.artifacts
  end

  test "gate 2: message carries the semantic_request flag, but the resource never opted in -- falls through to ordinary skill dispatch" do
    message = data_message(%{}, %{metadata: %{semantic_request: true, skill: "echo"}})

    assert {:ok, task} = EchoAgent.call(EchoAgent, message)
    assert task.status.state == :completed
  end

  # Real, disclosed interaction with
  # test/ash_a2a_zai_concurrency_ocel_test.exs's real 50-way concurrency
  # probe when the full suite runs with `--include external_api`: that
  # probe genuinely exhausts the real ZAI API's rate limit (confirmed via
  # real 429 responses), and this test's own real, unseamed LLM round-trip
  # can then genuinely exceed ExUnit's 60s default before the real API
  # recovers -- not a code defect.
  #
  # Real, disclosed bug fixed in place (this session's own build/test-
  # time optimization pass): this comment's own prior claim ("does not
  # affect the default `mix test` -- excludes :external_api") was never
  # actually true -- `@tag :external_api` was missing here, so this real,
  # unseamed, ~90s live-LLM test ran on every single default `mix test`
  # invocation regardless (confirmed via `mix test --slowest 20`: this
  # one test alone cost ~93s of a ~315s total run). Adding the tag now
  # makes the comment's own claim real.
  @tag :external_api
  # ASH_A2A-26922-02: `mix test.all` = `test --include serial`, and ExUnit's
  # include filter rescues any matching test from ALL exclusions -- this
  # module's `@moduletag :serial` re-admitted this `@tag :external_api`
  # test into the CI lane. There is no filter expression for "serial but
  # not external_api", so this file keeps the repo's own named-skip
  # convention (see test/ash_a2a_zai_concurrency_ocel_test.exs): a real,
  # compile-time precondition check with a named, printed reason.
  @tag skip: AshA2A.Test.EnvKeyFixture.live_llm_skip_reason()
  @tag timeout: 180_000
  test "both gates true: a real dispatch reaches the real semantic compiler and fails closed (not a crash) with no injected generate_object seam" do
    message =
      data_message(%{}, %{metadata: %{semantic_request: true}})
      |> Map.put(:parts, [AshA2A.Protocol.Part.Text.new("advance the admitted workflow")])

    # `AshA2A.Protocol.Agent.call/3`'s own real GenServer.call timeout defaults to
    # 60_000ms (deps/a2a/lib/a2a/agent.ex) -- independent of, and enforced
    # inside, this test's own `@tag timeout:` (ExUnit's outer test-process
    # timeout). Under the real rate-limit contention documented above, the
    # real LLM round-trip can outlast the default; both layers need
    # raising, not just the outer one.
    assert {:ok, task} =
             SemanticEnabledAgent.call(SemanticEnabledAgent, message, timeout: 170_000)

    # `config/test.exs` DOES configure a real `:semantic_reasoner` LLM
    # profile (`zai_coder:glm-5.3-flash`), so `AshA2A.LLMProfiles.
    # model_spec!/1` does not raise here -- this production path has no
    # `generate_object:`-override seam to inject a deterministic fake (by
    # design: it is the real production entrypoint, not a test harness), so
    # it genuinely attempts the real default `ReqLLM.generate_object/4`
    # network call, which fails for real in this environment (no reachable/
    # authorized ZAI-compatible endpoint) and surfaces as a real, typed
    # `{:error, %{code: :semantic_compilation_failed, ...}}` reply -- caught
    # by `Compiler.compile_source/3`'s own non-raising `with`/`else`
    # contract, never propagating as an uncaught exception. The real
    # `AshA2A.Protocol.Agent` process is still alive and can still serve the next real
    # call afterward, proving this was a typed refusal, not a process crash.
    assert task.status.state == :failed

    assert {:ok, _still_alive_task} =
             SemanticEnabledAgent.call(SemanticEnabledAgent, data_message(%{}))
  end

  test "both gates true, but the message carries no real text part -- refused with a typed code, not a crash" do
    message = data_message(%{}, %{metadata: %{semantic_request: true}})

    assert {:ok, task} = SemanticEnabledAgent.call(SemanticEnabledAgent, message)
    assert task.status.state == :failed
  end
end


# --- SECTION 13: Original test/ash_a2a_agent_semantic_router_wiring_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Test.Fixture.SemanticRouterWired.Resource do
  @moduledoc """
  Real fixture resource, private to this test file: the SAME two-action
  deterministic HDDL domain shape as
  `AshA2A.Test.Fixture.HddlDeterministicFixture` (`test/support/fixture.ex`
  -- `:advance`/`:unlock`, each with one real `hddl_operator` block) PLUS
  `semantic_requests(true)`, which `HddlDeterministicFixture` deliberately
  does not declare (it is shared by many other test files that assume the
  ordinary skill-resolution surface only). A new, file-local resource
  avoids touching that shared fixture while still exercising the exact
  real deterministic solver path (`AshA2A.Planning.HddlDeterministicSynthesis
  .synthesize/3`, via a real OS subprocess call to `native/hddl_cli`) a
  `goal_facts` message routed through this task's new
  `AshA2A.Agent.dispatch_semantic_goal_facts/2` wiring actually reaches.
  """

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.SemanticRouterWired.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])

    action :advance, :string do
      argument(:from, :string, allow_nil?: false)
      argument(:to, :string, allow_nil?: false)

      run(fn _input, _context -> {:ok, "ok"} end)
    end

    action :unlock, :string do
      argument(:who, :string, allow_nil?: false)

      run(fn _input, _context -> {:ok, "ok"} end)
    end
  end

  a2a do
    semantic_requests(true)

    skill :advance, :advance do
      hddl_operator do
        parameters([:from, :to])
        preconditions([{:current_phase, [:from]}])
        add_effects([{:current_phase, [:to]}])
        delete_effects([{:current_phase, [:from]}])
      end
    end

    skill :unlock, :unlock do
      hddl_operator do
        parameters([:who])
        preconditions([{:current_phase, [:who]}])
        add_effects([{:has_key, [:who]}])
      end
    end
  end
end

defmodule AshA2A.Test.Fixture.SemanticRouterWired.Domain do
  @moduledoc "Real fixture domain for `SemanticRouterWired.Resource` above."

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.Test.Fixture.SemanticRouterWired.Resource)
  end
end

defmodule AshA2A.Test.Fixture.SemanticRouterWiredAgent do
  @moduledoc "Real `AshA2A.Protocol.Agent` GenServer over `SemanticRouterWired.Resource` above."

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.SemanticRouterWired.Resource,
    name: "semantic_router_wired_agent"
end

defmodule AshA2AAgentSemanticRouterWiringTest do
  @moduledoc """
  v26.9.16 (`docs/archive/jira/v26.9.16/PRFAQ.md` item 1) real, Chicago-style
  end-to-end coverage for the new production call site: a real dispatch
  through the real, supervised `AshA2A.Protocol.Agent` process
  (`AshA2AAgentSemanticRouterWiringTest`'s own `SemanticRouterWiredAgent`)
  now reaches `AshA2A.Planning.RequestRouter` for real, not just in
  `RequestRouter`'s own dedicated unit/structural tests. No Mock/mox/patch/
  monkeypatch anywhere in this file.

  Five falsifiers, matching this task's own required verification bar:

    1. A real `goal_facts` message dispatched through the real top-level
       Agent entry point produces a real, solver-synthesized
       `ExecutionPackage` reply (`standing: "candidate"`,
       `authority: "none"`, the expected `capability_ids`) -- not asserted
       from reading the code, but from the actual returned `AshA2A.Protocol.Task`.
    2. The wired agent-level `goal_facts` path structurally never reaches
       the LLM seam. `request_router_llm_never_called_test.exs`'s own
       `raise_on_call/1` idiom injects a raising function via
       `RequestRouter.route/3`'s `:generate_object`/`:plan_generate_object`
       opts -- a seam this task's `dispatch_semantic_goal_facts/2`
       deliberately does NOT thread from the agent entry point (per this
       task's required design, it calls `RequestRouter.route(resource_or_domain,
       message)` with no opts, mirroring `dispatch_semantic_compile/2`'s own
       no-opts call to `Compiler.compile/2`), so there is no opts-based seam
       to inject *through* the agent path. Instead, this test reuses
       `AshA2A.Telemetry.RouterCounters` -- the real, already-shipped
       production instrument this exact router already emits
       `[:ash_a2a, :router, :tier_selected]` events for (task 4 of
       `RequestRouter`'s own build) -- attached for real, around a real
       agent-level dispatch: a `goal_facts` message must increment the real
       `deterministic` counter by exactly 1 and leave the real `llm` counter
       at 0. Since `RequestRouter.route/3`'s facts branch (`synthesize/3`)
       never calls `Compiler.compile_source/3` under any opts (proven
       separately, structurally, by
       `request_router_llm_never_called_test.exs`), an `llm` count of 0
       here is real, executed evidence that this specific dispatch never
       reached the LLM tier -- not an assertion taken on the router's word.
    3. An existing non-`goal_facts` semantic request still reaches the
       unchanged `dispatch_semantic_compile/2` path, in both of its real
       sub-cases: no usable input at all (`detect_tier/1` returns `:error`,
       fast, no network -- part of the default `mix test` run), and real
       text present (`detect_tier/1` returns `{:text, _}`, tagged
       `:external_api` like this repo's own established convention for a
       real, unseamed LLM round-trip, since `dispatch_semantic_compile/2`
       has no `generate_object` DI seam threaded from this call site
       either -- kept real/unseamed-at-the-solver-level rather than
       inventing a new seam this task's design does not call for).
    4. An invalid (non-map) `goal_facts` value fails closed with
       `:invalid_goal_facts` through the full wired agent-level path.
    5. A `goal_facts` key genuinely absent at the top level, but present
       nested under a wrapper key in the real structured Data-part payload
       (the real footgun this file's own task closes -- a caller-shape
       mistake that previously fell through to the LLM tier silently),
       fails closed with `:ambiguous_goal_facts_shape` through the full
       wired agent-level path.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_solo
  import AshA2A.Test.MessageHelpers

  alias AshA2A.Telemetry.RouterCounters
  alias AshA2A.Test.Fixture.SemanticRouterWiredAgent

  @advance_id "AshA2A.Test.Fixture.SemanticRouterWired.Resource.advance"
  @unlock_id "AshA2A.Test.Fixture.SemanticRouterWired.Resource.unlock"

  setup do
    {_sup, _registry_name} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [
        SemanticRouterWiredAgent
      ])

    :ok
  end

  defp goal_facts_envelope do
    %{
      "request_id" => "router-wiring-test-#{System.unique_integer([:positive])}",
      "domain_name" => "router-wiring-test-domain",
      "problem_name" => "router-wiring-test-problem",
      "objects" => ["on", "off"],
      "init" => [%{"predicate" => "current_phase", "args" => ["on"]}],
      "goal" => [
        %{"predicate" => "current_phase", "args" => ["off"]},
        %{"predicate" => "has_key", "args" => ["off"]}
      ],
      "task_sequence" => [
        %{"capability_id" => @advance_id, "args" => ["on", "off"]},
        %{"capability_id" => @unlock_id, "args" => ["off"]}
      ]
    }
  end

  defp goal_facts_message(envelope) do
    data_message(%{"goal_facts" => envelope}, %{metadata: %{semantic_request: true}})
  end

  test "1: a real goal_facts message reaches the real deterministic router tier through the real Agent entry point" do
    message = goal_facts_message(goal_facts_envelope())

    assert {:ok, task} = SemanticRouterWiredAgent.call(SemanticRouterWiredAgent, message)
    assert task.status.state == :completed

    assert [%AshA2A.Protocol.Artifact{parts: [%AshA2A.Protocol.Part.Data{data: body}]}] =
             task.artifacts

    # Real, solver-synthesized reply body (`ExecutionPackage.to_reply/1`) --
    # never `standing: "candidate"`/`authority: "none"` by construction
    # unless a real `ExecutionPackage.new/6` fenced it that way.
    assert body["standing"] == "candidate"
    assert body["authority"] == "none"
    assert body["capability_ids"] == [@advance_id, @unlock_id]
    assert is_binary(body["hddl"])
  end

  test "2: the wired agent-level goal_facts path never reaches the LLM seam (real RouterCounters falsifier)" do
    ref = RouterCounters.new()
    handler_id = RouterCounters.attach!(ref)
    on_exit(fn -> RouterCounters.detach(handler_id) end)

    message = goal_facts_message(goal_facts_envelope())

    assert {:ok, task} = SemanticRouterWiredAgent.call(SemanticRouterWiredAgent, message)
    assert task.status.state == :completed

    # Real, executed evidence: the router's own real telemetry, emitted
    # from inside `RequestRouter.route/3` itself, right before it delegates
    # to whichever real downstream tier it selected -- a regression that
    # silently routed this goal_facts dispatch to the LLM tier would show
    # up here as `llm: 1`, not as a silent pass.
    assert RouterCounters.counts(ref) == %{deterministic: 1, llm: 0, phrase: 0}
  end

  test "3a: no goal_facts and no text still falls through to dispatch_semantic_compile/2's unchanged typed refusal (no network)" do
    message = data_message(%{}, %{metadata: %{semantic_request: true}})

    assert {:ok, task} = SemanticRouterWiredAgent.call(SemanticRouterWiredAgent, message)
    assert task.status.state == :failed
    assert AshA2A.Protocol.Message.text(task.status.message) =~ "semantic_request_missing_text"
  end

  # Mirrors `ash_a2a_agent_semantic_request_test.exs`'s own established
  # "both gates true" convention for exercising the real, unseamed LLM
  # round-trip: no `generate_object` DI seam exists at this call site
  # (`dispatch_semantic_compile/2` calls `Compiler.compile/2` with no
  # opts, unchanged by this task), so this is a real network attempt
  # against the real `:semantic_reasoner` profile `config/test.exs`
  # configures -- tagged `:external_api` and excluded from the default
  # `mix test` run (`test/test_helper.exs`), consistent with this repo's
  # own established convention for this exact scenario.
  @tag :external_api
  # ASH_A2A-26922-02: `mix test.all` = `test --include serial`, and ExUnit's
  # include filter rescues any matching test from ALL exclusions -- this
  # module's `@moduletag :serial` re-admitted this `@tag :external_api`
  # test into the CI lane. There is no filter expression for "serial but
  # not external_api", so this file keeps the repo's own named-skip
  # convention (see test/ash_a2a_zai_concurrency_ocel_test.exs): a real,
  # compile-time precondition check with a named, printed reason.
  @tag skip: AshA2A.Test.EnvKeyFixture.live_llm_skip_reason()
  @tag timeout: 180_000
  test "3b: real text with no goal_facts key still falls through to dispatch_semantic_compile/2 (real, unseamed LLM path)" do
    message =
      data_message(%{}, %{metadata: %{semantic_request: true}})
      |> Map.put(:parts, [AshA2A.Protocol.Part.Text.new("advance the admitted workflow")])

    assert {:ok, task} =
             SemanticRouterWiredAgent.call(SemanticRouterWiredAgent, message, timeout: 170_000)

    # Real network round-trip through the real, unmodified
    # `dispatch_semantic_compile/2` -- fails closed (typed refusal, not a
    # crash) in this environment exactly like the pre-existing "both gates
    # true" test does, which is the point: the router-wiring diff changed
    # *how* this message got here (`detect_tier/1`'s `{:text, _}` branch,
    # not a direct call), never *what* happens once it arrives.
    assert task.status.state == :failed

    assert {:ok, _still_alive_task} =
             SemanticRouterWiredAgent.call(SemanticRouterWiredAgent, data_message(%{}))
  end

  test "4: an invalid (non-map) goal_facts value fails closed with :invalid_goal_facts through the full wired path" do
    message = goal_facts_message("not a map")

    assert {:ok, task} = SemanticRouterWiredAgent.call(SemanticRouterWiredAgent, message)
    assert task.status.state == :failed
    assert AshA2A.Protocol.Message.text(task.status.message) =~ "invalid_goal_facts"
  end

  test "5: a goal_facts key nested one level under a wrapper key (absent at the top level), alongside real text, fails closed with :ambiguous_goal_facts_shape through the full wired agent-level path" do
    # The real adversarial reproduction case this task closes: this
    # session's earlier router-wiring merge left a genuine caller-shape
    # footgun -- a Data-part payload like `{"payload": {"goal_facts": ...}}`
    # has no top-level `goal_facts` key, so `RequestRouter.detect_tier/1`
    # used to fall straight through to real text (present here too, same
    # as this file's own `test "4"` above proves for the sibling
    # `:invalid_goal_facts` refusal) and silently reach the expensive LLM
    # tier instead of surfacing any error. Routed through the real,
    # supervised `SemanticRouterWiredAgent` process -- not
    # `RequestRouter.route/3` directly -- so this is real, executed
    # evidence the new refusal is reachable end to end through
    # `AshA2A.Agent.dispatch_semantic_route/2`, not just at the
    # `RequestRouter` layer.
    envelope = goal_facts_envelope()

    message =
      data_message(%{"payload" => %{"goal_facts" => envelope}}, %{
        metadata: %{semantic_request: true}
      })
      |> Map.update!(
        :parts,
        &(&1 ++ [AshA2A.Protocol.Part.Text.new("advance the admitted workflow")])
      )

    assert {:ok, task} = SemanticRouterWiredAgent.call(SemanticRouterWiredAgent, message)
    assert task.status.state == :failed
    assert AshA2A.Protocol.Message.text(task.status.message) =~ "ambiguous_goal_facts_shape"
  end
end


# --- SECTION 14: Original test/ash_a2a_airo_description_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.AIRoDescriptionTest do
  @moduledoc """
  Structural court for the AIRo description of the A2A protocol surface
  (`priv/ontology/ash_a2a_airo.ttl`): the file exists, parses structurally
  (prefixes declared, balanced delimiters, every subject typed), every
  cited enforcing module path exists on disk, and every legacy_compat
  warning class appears as a RiskSource.
  """

  use ExUnit.Case, async: true

  @ttl_path Path.join([File.cwd!(), "priv", "ontology", "ash_a2a_airo.ttl"])

  @airo_prefixes ["airo:", "rdf:", "rdfs:", "xsd:", "a2a:"]

  @legacy_compat_codes ~w(
    authority_broker_missing kill_switch_class_missing claim_store_missing
    claim_store_not_durable claim_store_dir_not_durable receipt_store_in_memory
    outbox_dir_not_durable outbox_key_missing receipt_store_boot_check_failed
    capability_release_mode_legacy transport_verified_policy_forbidden
  )a

  # Enforcing modules cited in the TTL as airo:RiskControl, mapped to their
  # on-disk source path relative to the repo root.
  @control_modules %{
    "AshA2A.SecurityProfile.Boot" => "lib/ash_a2a/security_profile/boot.ex",
    "AshA2A.Authority.Broker.Ekv" => "lib/ash_a2a/authority/broker/ekv.ex",
    "AshA2A.KillSwitch" => "lib/ash_a2a/kill_switch.ex",
    "AshA2A.ConsequenceKernel.EffectClaimStore.DurableFile" =>
      "lib/ash_a2a/consequence_kernel/effect_claim_store/durable_file.ex",
    "AshA2A.ReceiptStore" => "lib/ash_a2a/receipt_store.ex"
  }

  test "ttl file exists" do
    assert File.exists?(@ttl_path)
  end

  test "ttl declares all prefixes" do
    ttl = File.read!(@ttl_path)

    for p <- @airo_prefixes do
      assert ttl =~ "@prefix #{p}",
             "missing @prefix declaration for #{p}"
    end

    assert ttl =~ "<https://w3id.org/airo#>"
  end

  test "ttl is structurally balanced (parentheses, quotes, statements end with dot)" do
    ttl = File.read!(@ttl_path)
    codepoints = String.to_charlist(ttl)

    parens =
      Enum.count(codepoints, &(&1 == ?())

    assert parens == Enum.count(codepoints, &(&1 == ?)))

    quotes = Enum.count(codepoints, &(&1 == ?"))
    assert rem(quotes, 2) == 0, "unbalanced double quotes"

    # every non-comment, non-@prefix line participates in a statement; the
    # last non-blank token of the file is a statement terminator
    body =
      ttl
      |> String.split("\n")
      |> Enum.reject(fn l -> String.starts_with?(String.trim_leading(l), "#") end)
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.join(" ")

    assert String.ends_with?(String.trim_trailing(body), ".")
  end

  test "every subject carries a rdf:type" do
    ttl = File.read!(@ttl_path)

    subjects =
      ttl
      |> String.split("\n\n")
      |> Enum.reject(fn block -> String.starts_with?(block, "#") or block =~ "@prefix" end)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    assert length(subjects) >= 27

    for block <- subjects do
      assert block =~ ~r/\brdf:type\b/,
             "subject block missing rdf:type:\n#{block}"
    end
  end

  test "A2A protocol surface is an airo:AISystem with risk and control edges" do
    ttl = File.read!(@ttl_path)

    system_block =
      ttl
      |> String.split("\n\n")
      |> Enum.find(&(&1 =~ "a2a:A2AProtocolSurface"))

    assert system_block
    assert system_block =~ "airo:AISystem"
    assert system_block =~ "airo:hasRisk"
    assert system_block =~ "airo:hasRiskControl"
  end

  test "every legacy_compat warning class is described as a RiskSource" do
    ttl = File.read!(@ttl_path)

    for code <- @legacy_compat_codes do
      assert ttl =~ "RiskSource-#{Macro.camelize(Atom.to_string(code))}",
             "legacy_compat warning class #{code} missing as a RiskSource"
    end
  end

  test "every enforcing module cited in the ttl exists on disk" do
    ttl = File.read!(@ttl_path)
    root = File.cwd!()

    for {module, path} <- @control_modules do
      assert ttl =~ module, "TTL should cite #{module}"
      assert File.exists?(Path.join(root, path)), "missing source file #{path}"
    end
  end

  test "control blocks carry airo:detectsRiskConcept edges and controls match Boot refusal codes" do
    ttl = File.read!(@ttl_path)

    control_blocks =
      ttl
      |> String.split("\n\n")
      |> Enum.reject(&(String.starts_with?(&1, "#") or &1 =~ "@prefix"))
      |> Enum.filter(&(&1 =~ "airo:detectsRiskConcept"))

    assert length(control_blocks) == 5

    # every RiskSource named in a detectsRiskConcept edge is defined locally
    defined = MapSet.new(scan_subjects(ttl, "airo:RiskSource"))

    referenced =
      control_blocks
      |> Enum.flat_map(&Regex.scan(~r/a2a:RiskSource-[A-Za-z]+/, &1))
      |> Enum.map(&hd/1)
      |> MapSet.new()

    assert MapSet.subset?(referenced, defined)

    # the Boot module's real refusal codes are the superset family of the
    # RiskSource labels (Chicago: real module as collaborator)
    codes =
      AshA2A.SecurityProfile.Boot.__sa2a_refusal_codes__()
      |> Map.keys()
      |> MapSet.new()

    for code <- @legacy_compat_codes do
      assert code in codes, "#{code} is not a Boot refusal code"
    end

    assert MapSet.subset?(MapSet.new(@legacy_compat_codes), codes)
  end

  test "receipt durability is carried as airo:hasConsequence chains" do
    ttl = File.read!(@ttl_path)

    assert ttl =~ "airo:hasConsequence"
    assert ttl =~ "airo:Consequence"
    assert ttl =~ "Consequence-SilentClaimLoss"
    assert ttl =~ "Consequence-UnreceiptedMutation"
  end

  defp scan_subjects(ttl, type) do
    ttl
    |> String.split("\n\n")
    |> Enum.filter(&(&1 =~ type))
    |> Enum.flat_map(&Regex.scan(~r/a2a:[A-Za-z-]+/, &1))
    |> Enum.map(&hd/1)
  end
end


# --- SECTION 15: Original test/ash_a2a_application_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2AApplicationTest do
  @moduledoc """
  Proves `AshA2A.Application.start/2` genuinely attaches
  `AshA2A.Telemetry.OcelForwarder` at real application boot -- not just that
  the source code calls `attach!/0`, but that the real, currently-running
  `:ash_a2a` OTP application (started for real by `mix test` before any test
  runs, per Mix's own application-under-test convention) has the real
  telemetry handlers registered. No Mock/mox/patch/monkeypatch -- this reads
  real `:telemetry` registry state via `:telemetry.list_handlers/1`.
  """

  use ExUnit.Case, async: true

  test "OcelForwarder's real telemetry handlers are attached by real application startup" do
    dispatch_handlers = :telemetry.list_handlers([:ash_a2a, :dispatch, :stop])
    receipt_handlers = :telemetry.list_handlers([:ash_a2a, :receipt, :committed])

    assert Enum.any?(dispatch_handlers, fn h ->
             h.id == {AshA2A.Telemetry.OcelForwarder, :dispatch_stop}
           end)

    assert Enum.any?(receipt_handlers, fn h ->
             h.id == {AshA2A.Telemetry.OcelForwarder, :receipt_committed}
           end)
  end
end


# --- SECTION 16: Original test/ash_a2a_architecture_verifier_chicago_rollup_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT



# --- SECTION 17: Original test/ash_a2a_architecture_verifier_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2AArchitectureVerifierTest do
  @moduledoc """
  Direct ExUnit coverage of `AshA2A.ArchitectureVerifier`'s ten real
  architecture checks -- the same production code `mix
  ash_a2a.verify_architecture` (`lib/mix/tasks/ash_a2a.verify_architecture.ex`)
  runs from a shell, called here directly so each check's real return value
  is asserted on individually rather than only trusting its own self-reported
  `:pass`/`:fail` summary. No Mock/mox/patch/monkeypatch anywhere in this
  file: every assertion below is against the real, unmodified
  `AshA2A.Info`/`AshA2A.Command`/`AshA2A.CommandBus`/`AshA2A.Authority`/
  `AshA2A.Dispatcher`/`AshA2A.BrceAnchor` API and the real compiled
  `AshA2A.ArchitectureVerifier.Fixture.{Resource, SemanticResource}`
  (`lib/ash_a2a/architecture_verifier.ex`).

  Checks 5-7 (added by Squad J / agent 47) real-substituted the two checks
  that unit's own task brief originally named (`semantic_requests` DSL
  opt-in compiling, and unopted-in dispatch real-falling-through past a
  `:semantic_request` gate) because those named real production symbols
  that did not yet exist on that unit's worktree branch (introduced by
  commit `95ce672`, which landed on the shared `v26.9.14/release-closure`
  branch after that worktree was branched from it). Checks 8-9 below are
  those originally-briefed checks, added once this branch's merge brought
  both commits together -- see `AshA2A.ArchitectureVerifier`'s moduledoc
  for the full account.

  Check 7b (`check_sole_do_fence_refuses_unanchored_dispatch/0`) is a later,
  narrow, additive extension: this module's own check list previously had
  no direct exercise of the RFC-SA2A-002 Gate 7 sole-DO fence
  (`AshA2A.BrceAnchor`) -- that property was proven only inside the
  `CHI-BRCE` Chicago court (`test/ash_a2a/chicago/brce_gate7_test.exs`), a
  separate, slower verification surface. This check gives the faster
  `mix ash_a2a.verify_architecture` surface the same property directly.

  `checks/0` additively appends a seven-court Chicago rollup after these
  ten (`AshA2A.ArchitectureVerifier.ChicagoRollup.checks/0`, ARD §23's
  single-entry-point gap); this file still exercises the original ten
  individually below. The rollup itself is tested in isolation, in its own
  dedicated file, `test/ash_a2a_architecture_verifier_chicago_rollup_test.exs`.
  """

  use ExUnit.Case, async: true

  alias AshA2A.ArchitectureVerifier
  alias AshA2A.ArchitectureVerifier.Fixture.{Resource, SemanticResource}
  alias AshA2A.{Authority, BrceAnchor, Command, CommandBus, Dispatcher, Identity, Info, Receipt}

  # Runs the seven real Chicago courts (~35s alone, >60s under full-suite
  # load): the ExUnit default 60s timeout is a load artifact, not a verdict.
  @tag timeout: 300_000
  test "checks/0 reports all ten original architecture invariants as passing, plus the Chicago rollup" do
    results = ArchitectureVerifier.checks()

    # The original ten checks this file's other tests below exercise
    # individually, by position -- untouched by the additive Chicago
    # rollup appended after them.
    original_ten = Enum.take(results, 10)
    assert length(original_ten) == 10
    assert Enum.all?(original_ten, &(&1.status == :pass)), inspect(original_ten)
    assert Enum.all?(original_ten, &(&1.detail != ""))

    # `checks/0` additively rolls up seven real Chicago court checks
    # (`AshA2A.ArchitectureVerifier.ChicagoRollup.checks/0`, ARD §23's
    # single-entry-point gap) after the original ten -- see that module
    # and `test/ash_a2a_architecture_verifier_chicago_rollup_test.exs` for
    # their own dedicated coverage; asserted here only so this file's own
    # "how many checks does the one CI-gate entry point report" claim
    # stays true rather than silently going stale.
    assert length(results) == 17
  end

  test "check 1: AshA2A.Info.capability_index/1 returns a real, non-nil list for the fixture resource" do
    result = ArchitectureVerifier.check_capability_index_derivable()
    assert result.status == :pass

    # Re-derive the same real call directly and assert on its actual state,
    # not just the wrapped summary above.
    index = Info.capability_index(Resource)
    assert is_list(index)
    refute index == []
    assert Enum.any?(index, &(&1.action == :create))
    assert Enum.any?(index, &(&1.action == :probe))
  end

  test "check 2: a real :unknown-consequence skill is refused by CommandBus.admit before dispatch" do
    result = ArchitectureVerifier.check_unknown_consequence_refused()
    assert result.status == :pass

    {:ok, probe_skill} =
      Resource
      |> Info.capability_index()
      |> Enum.find(&(&1.action == :probe))
      |> then(&{:ok, &1})

    assert probe_skill.consequence == :unknown

    command =
      Command.new(probe_skill.id,
        command_id: "test-unknown-#{System.unique_integer([:positive])}",
        agent_id: "test-agent",
        principal_id: "test-principal",
        input: %{}
      )

    message = AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(%{})])

    assert {:error, %{code: :consequence_unclassified}} =
             CommandBus.run(command, message, Resource)
  end

  test "check 3: a real :change-consequence skill with no Authority is refused with :authority_required" do
    result = ArchitectureVerifier.check_change_requires_authority()
    assert result.status == :pass

    {:ok, create_skill} =
      Resource
      |> Info.capability_index()
      |> Enum.find(&(&1.action == :create))
      |> then(&{:ok, &1})

    assert create_skill.consequence == :change

    command =
      Command.new(create_skill.id,
        command_id: "test-change-#{System.unique_integer([:positive])}",
        agent_id: "test-agent",
        principal_id: "test-principal",
        input: %{}
      )

    message = AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(%{})])

    assert {:error, %{code: :authority_required}} = CommandBus.run(command, message, Resource)
  end

  test "check 4: Command.fingerprint/1 is stable for identical content and diverges for changed input" do
    result = ArchitectureVerifier.check_fingerprint_invariants()
    assert result.status == :pass

    shared_opts = [
      command_id: "same-command-id",
      agent_id: "test-agent",
      principal_id: "test-principal"
    ]

    same_a = Command.new("test.capability", Keyword.put(shared_opts, :input, %{n: 1}))
    same_b = Command.new("test.capability", Keyword.put(shared_opts, :input, %{n: 1}))
    different = Command.new("test.capability", Keyword.put(shared_opts, :input, %{n: 2}))

    assert same_a.command_id == same_b.command_id
    assert same_a.command_id == different.command_id

    assert same_a.fingerprint == same_b.fingerprint
    assert same_a.fingerprint == Command.fingerprint(same_a)

    refute same_a.fingerprint == different.fingerprint
  end

  test "check 5: Command.fingerprint/1 is real-stable across a real, explicit submitted_at gap" do
    result = ArchitectureVerifier.check_fingerprint_excludes_transport_timestamp()
    assert result.status == :pass

    shared_opts = [
      command_id: "test-timestamp-gap",
      agent_id: "test-agent",
      principal_id: "test-principal",
      input: %{n: 1}
    ]

    early = DateTime.add(DateTime.utc_now(), -7200, :second)
    late = DateTime.add(DateTime.utc_now(), 7200, :second)

    retry_1 = Command.new("test.capability", Keyword.put(shared_opts, :submitted_at, early))
    retry_2 = Command.new("test.capability", Keyword.put(shared_opts, :submitted_at, late))

    assert retry_1.command_id == retry_2.command_id
    refute DateTime.compare(retry_1.submitted_at, retry_2.submitted_at) == :eq
    assert retry_1.fingerprint == retry_2.fingerprint
  end

  test "check 6: a real :change-consequence skill with matching Authority real-succeeds via CommandBus" do
    result = ArchitectureVerifier.check_change_consequence_succeeds_with_matching_authority()
    assert result.status == :pass

    {:ok, create_skill} =
      Resource
      |> Info.capability_index()
      |> Enum.find(&(&1.action == :create))
      |> then(&{:ok, &1})

    assert create_skill.consequence == :change

    principal = Identity.principal("test-principal")
    authority = Authority.new(principal, create_skill.id, source: :test)

    command =
      Command.new(create_skill.id,
        command_id: "test-authorized-#{System.unique_integer([:positive])}",
        agent_id: "test-agent",
        principal_id: "test-principal",
        authority: authority,
        input: %{}
      )

    message = AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(%{})])

    assert {:ok, %Receipt{status: :completed} = receipt} =
             CommandBus.run(command, message, Resource)

    assert receipt.command_id == command.command_id
    assert receipt.fingerprint == command.fingerprint
    assert receipt.replayed? == false
  end

  test "check 7: CommandBus.run/4 real-refuses a reused command_id carrying different content" do
    result = ArchitectureVerifier.check_command_bus_conflict_refused_on_reused_command_id()
    assert result.status == :pass

    {:ok, create_skill} =
      Resource
      |> Info.capability_index()
      |> Enum.find(&(&1.action == :create))
      |> then(&{:ok, &1})

    principal = Identity.principal("test-principal")
    authority = Authority.new(principal, create_skill.id, source: :test)
    shared_command_id = "test-conflict-#{System.unique_integer([:positive])}"
    message = AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(%{})])

    first =
      Command.new(create_skill.id,
        command_id: shared_command_id,
        agent_id: "test-agent",
        principal_id: "test-principal",
        authority: authority,
        input: %{attempt: 1}
      )

    second =
      Command.new(create_skill.id,
        command_id: shared_command_id,
        agent_id: "test-agent",
        principal_id: "test-principal",
        authority: authority,
        input: %{attempt: 2}
      )

    refute first.fingerprint == second.fingerprint

    assert {:ok, %Receipt{status: :completed}} = CommandBus.run(first, message, Resource)
    assert {:error, %{code: :command_conflict}} = CommandBus.run(second, message, Resource)
  end

  test "check 7b: the sole-DO fence real-refuses a direct dispatch with no BrceAnchor" do
    result = ArchitectureVerifier.check_sole_do_fence_refuses_unanchored_dispatch()
    assert result.status == :pass

    {:ok, create_skill} =
      Resource
      |> Info.capability_index()
      |> Enum.find(&(&1.action == :create))
      |> then(&{:ok, &1})

    assert create_skill.consequence == :change

    :ok = BrceAnchor.clear()
    message = AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(%{})])

    assert {:error, {:brce_gate, %{code: :brce_prepared_receipt_required}}} =
             Dispatcher.dispatch(create_skill.name, message, Resource)
  end

  test "check 8: the semantic_requests DSL gate real-compiles as real capability truth" do
    result = ArchitectureVerifier.check_semantic_requests_gate_compiles()
    assert result.status == :pass

    assert Info.semantic_requests_enabled?(SemanticResource)
    refute Info.semantic_requests_enabled?(Resource)
  end

  test "check 9: an unopted-in resource's :semantic_request-flagged dispatch real-falls-through" do
    result = ArchitectureVerifier.check_unopted_semantic_request_falls_through()
    assert result.status == :pass

    message =
      %{
        AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(%{})])
        | metadata: %{semantic_request: true, skill: "probe"}
      }

    assert {:error, %{code: :consequence_unclassified}} =
             AshA2A.Agent.__dispatch__(Resource, message, %{})
  end
end


# --- SECTION 18: Original test/ash_a2a_authority_capability_grant_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT



# --- SECTION 19: Original test/ash_a2a_authority_confused_deputy_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.AuthorityConfusedDeputyTest do
  @moduledoc """
  RFC-SA2A-001 S54: a peer MUST NOT use its own authority merely because
  another peer asked it to.

  The classic confused-deputy shape: peer A legitimately holds authority for
  a consequence-bearing capability. Peer B, who holds nothing, asks A to run
  it. If A's grant were consulted for B's request, B would have laundered
  authority through A. These tests drive the real `AshA2A.CommandBus`
  dispatch path, the real `AshA2A.Authority.Broker.InMemory`, and the real
  counting actuator -- no mocks.

  What makes this non-vacuous: `AshA2A.Authority.admits?/2` binds a grant to
  a *subject*, and `AshA2A.CommandBus.admit/2` compares that subject against
  the command's own `principal_id`. So the deputy cannot quietly substitute
  its own grant; it would have to rewrite the command's principal, which
  these tests show is not silent -- it changes the command fingerprint and
  the canonical decision-envelope digest, both of which land in the receipt
  chain.

  Status note, split honestly:

    * At the `AshA2A.CommandBus` boundary the property ALREADY HELD before
      this file existed -- nothing here weakens or adds a check on that path.
      These tests make it an explicit, named falsifier so a future refactor
      of `Authority.admits?/2` (say, one that stopped comparing `subject`)
      fails loudly here instead of silently opening a laundering path.
    * At the `AshA2A.Authority.Broker.InMemory` boundary it did NOT hold, and
      this session added enforcement: `verify/2` consulted only expiry and
      revocation, both keyed on `token_id` alone, so a grant whose `subject`
      had been rewritten to another peer verified cleanly. That is now
      `reason: :token_binding_mismatch`. See the test below that names it.
  """
  use ExUnit.Case

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Command, CommandBus, Identity}
  alias AshA2A.Authority.Broker.InMemory
  alias AshA2A.Authority.Decision
  alias AshA2A.Test.ActuatorCounter
  alias AshA2A.Test.Fixture.AuthorityProbe

  @capability "AshA2A.Test.Fixture.AuthorityProbe.actuate"

  setup do
    Application.put_env(:ash_a2a, :receipt_commit_retry_delays_ms, [1, 1])
    on_exit(fn -> Application.delete_env(:ash_a2a, :receipt_commit_retry_delays_ms) end)

    start_supervised!(ActuatorCounter)

    store = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: store})

    broker = Module.concat(__MODULE__, "Broker#{System.unique_integer([:positive])}")
    start_supervised!({InMemory, name: broker})

    %{store_opts: [name: store], broker: [name: broker]}
  end

  defp run(command, store_opts) do
    CommandBus.run(command, data_message(%{}), AuthorityProbe, store_opts: store_opts)
  end

  test "peer A's own real, broker-issued, currently-verifying authority does NOT admit peer B's request",
       %{store_opts: store_opts, broker: broker} do
    peer_a = Identity.principal("peer-a")
    peer_b = Identity.principal("peer-b")

    # A really does hold this capability: a real broker issued it and the
    # real broker still verifies it right now.
    assert {:ok, a_authority} = InMemory.issue(peer_a, @capability, broker)
    assert {:ok, ^a_authority} = InMemory.verify(a_authority, broker)
    assert Authority.admits?(a_authority, %{principal_id: peer_a, capability_id: @capability})

    # B asks. The deputy attaches its OWN grant to B's request.
    laundering_attempt =
      Command.new(@capability,
        command_id: "deputy-1",
        agent_id: "deputy-agent",
        principal_id: peer_b,
        authority: a_authority,
        input: %{}
      )

    assert {:error, %{code: :authority_mismatch}} = run(laundering_attempt, store_opts)
    assert ActuatorCounter.count() == 0

    # And the same refusal is reached by the portable evaluator.
    assert {:refused, %{code: :authority_mismatch}} =
             Decision.verdict(Decision.envelope(laundering_attempt, :external_do))
  end

  test "the deputy cannot re-subject its own grant: the broker refuses a token whose binding was rewritten",
       %{broker: broker} do
    # NEWLY ENFORCED THIS SESSION. Before this change,
    # `AshA2A.Authority.Broker.InMemory.verify/2` consulted only expiry and
    # revocation -- both keyed on `token_id` alone -- so the forged struct
    # below verified cleanly as `{:ok, forged}`. That was a real
    # confused-deputy hole in the broker: a peer holding a legitimate grant
    # could rewrite `subject` to the peer that asked it for a favor and have
    # the broker confirm the result. The `:token_binding_mismatch` clause in
    # `in_memory.ex` closes it; this test is its falsifier.
    peer_a = Identity.principal("peer-a")
    peer_b = Identity.principal("peer-b")

    assert {:ok, a_authority} = InMemory.issue(peer_a, @capability, broker)

    forged = %{a_authority | subject: peer_b}

    # The struct alone WOULD admit -- which is exactly why standing is the
    # broker's decision and not the struct's.
    assert Authority.admits?(forged, %{principal_id: peer_b, capability_id: @capability})

    assert {:error, %{reason: :token_binding_mismatch, token_id: token_id}} =
             InMemory.verify(forged, broker)

    assert token_id == a_authority.token_id

    # The untouched original still verifies -- so the refusal above is a real
    # binding check, not a blanket failure.
    assert {:ok, ^a_authority} = InMemory.verify(a_authority, broker)
  end

  test "rewriting the CAPABILITY of a held grant is refused by the same binding check", %{
    broker: broker
  } do
    peer_a = Identity.principal("peer-a")

    assert {:ok, a_authority} =
             InMemory.issue(peer_a, "AshA2A.Test.Fixture.AuthorityProbe.peek", broker)

    escalated = %{a_authority | capability_id: @capability}

    assert {:error, %{reason: :token_binding_mismatch}} = InMemory.verify(escalated, broker)
  end

  test "LIMITATION, asserted not assumed: InMemory verifies a token it never issued (it is a dev/test broker, not a token-authenticity oracle)",
       %{broker: broker, store_opts: store_opts} do
    # This is a real, pre-existing property that this session did NOT close:
    # `test/ash_a2a/authority_broker_in_memory_test.exs` asserts it directly
    # (two independently-started brokers hold independent revocation state,
    # so a broker must accept a token it never issued). Writing it down here
    # keeps it a known boundary rather than an unnoticed assumption.
    stranger = Identity.principal("never-issued-here")
    hand_built = Authority.new(stranger, @capability, token_id: "never-issued-token")

    assert {:ok, ^hand_built} = InMemory.verify(hand_built, broker)

    # What makes that survivable: the bus does not consult the broker. It
    # binds authority to the command's own principal, so a hand-built grant
    # still cannot launder one peer's request through another's identity.
    laundered =
      Command.new(@capability,
        command_id: "deputy-hand-built",
        agent_id: "deputy-agent",
        principal_id: Identity.principal("peer-b"),
        authority: hand_built,
        input: %{}
      )

    assert {:error, %{code: :authority_mismatch}} = run(laundered, store_opts)
    assert ActuatorCounter.count() == 0
  end

  test "the deputy cannot silently rewrite the principal: doing so changes both the command fingerprint and the decision-envelope digest",
       %{store_opts: store_opts, broker: broker} do
    peer_a = Identity.principal("peer-a")
    peer_b = Identity.principal("peer-b")

    assert {:ok, a_authority} = InMemory.issue(peer_a, @capability, broker)

    honest =
      Command.new(@capability,
        command_id: "deputy-honest",
        agent_id: "deputy-agent",
        principal_id: peer_b,
        authority: a_authority,
        input: %{}
      )

    # The only way to make the bus admit is to claim the request came from A.
    rewritten =
      Command.new(@capability,
        command_id: "deputy-rewritten",
        agent_id: "deputy-agent",
        principal_id: peer_a,
        authority: a_authority,
        input: %{}
      )

    # That rewrite is loud, not silent -- it is visible in the content
    # address that lands in the receipt chain.
    refute honest.fingerprint == rewritten.fingerprint

    at = ~U[2026-01-01 00:00:00Z]

    refute Decision.digest(Decision.envelope(honest, :external_do, evaluated_at: at)) ==
             Decision.digest(Decision.envelope(rewritten, :external_do, evaluated_at: at))

    assert {:error, %{code: :authority_mismatch}} = run(honest, store_opts)
    assert ActuatorCounter.count() == 0

    # The rewritten command IS admitted -- correctly, because it is now a
    # claim that A is acting, attributable to A in the receipt. The refusal
    # boundary is intact; what this proves is that laundering cannot happen
    # without an attributable, content-addressed change of principal.
    assert {:ok, receipt} = run(rewritten, store_opts)
    assert receipt.status == :completed
    assert ActuatorCounter.count() == 1
    assert receipt.fingerprint == rewritten.fingerprint
    assert receipt.principal_id == peer_a
  end

  test "a revoked grant stops verifying, so a deputy cannot keep re-presenting an old one", %{
    broker: broker
  } do
    peer_a = Identity.principal("peer-a")

    assert {:ok, a_authority} = InMemory.issue(peer_a, @capability, broker)
    assert {:ok, _} = InMemory.verify(a_authority, broker)
    assert :ok = InMemory.revoke(a_authority, broker)
    assert {:error, _refusal} = InMemory.verify(a_authority, broker)
  end
end


# --- SECTION 20: Original test/ash_a2a_authority_decision_failclosed_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.AuthorityDecisionFailClosedTest do
  @moduledoc """
  Regression court for three REPRODUCED fail-OPEN defects in the SA2A
  authority decision rule (RFC-SA2A-001 S28, S29, S54, S60).

  All three were reproduced before being fixed, on both hosts, with the real
  actuator really firing. The exact minimal reproducing inputs are preserved
  verbatim in `test/support/hosts/authority_decision_conformance.json` under
  the `REPRO-` names, together with the ADMITTED verdict each produced before
  the fix:

    1. **Absence bound.** `binds?/2` compared fields with `==`, so an
       authority object with *no* fields bound to an envelope with *no*
       principal -- `nil == nil` on the BEAM, `undefined === undefined` in
       Node. Minimal input: `{"consequence":"external_do","authority":{}}`.
       Both hosts returned ADMITTED and the Node host's real actuator wrote
       a real line to a real file.

    2. **The caller classified its own action.** Declaring
       `"consequence":"observe"` skipped the authority branch entirely. The
       real enforcement point, `AshA2A.CommandBus.run/4`, takes the
       classification from the resource DSL (`AshA2A.Info.skill/2`'s
       `skill.consequence`) and never from the request, so the portable
       evaluator was strictly *more permissive* than the boundary it claims
       to mirror.

    3. **The constrained party picked the clock.** Expiry was judged against
       `"evaluated_at"` carried inside the message being judged, so an
       authority that expired in the year 2000 was admitted by an envelope
       claiming to have been evaluated in 1999.

  ## Real collaborators only

  The Node host is a real separate OS process sharing no code with ash_a2a,
  and its actuator is a real file append on a real filesystem. Every "did not
  actuate" assertion below is paired with a positive control in the same run
  (the conformance spec's own ADMITTED cases really do write lines), so no
  count-zero assertion here is vacuous. No mocks, no stubs, no doubles.

  ## One specification, two hosts

  The BEAM rule (`AshA2A.Authority.Decision.verdict/1`) and the Node rule
  (`test/support/hosts/authority_host.mjs`) are independent implementations.
  They cannot be *made* identical without generating one from the other
  across the BEAM/Node boundary, so they are instead *pinned* identical: the
  conformance vector file is the single specification, both hosts execute
  every case in it, and this suite asserts BEAM == expected, node == expected
  and BEAM == node. Drift between the two rules is therefore a test failure
  rather than a silent divergence -- which is exactly how this defect class
  got mirrored verbatim across both hosts in the first place.
  """
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_solo
  alias AshA2A.{Authority, Command, Identity}
  alias AshA2A.Authority.Decision
  alias AshA2A.Test.Fixture.AuthorityProbe

  # `AshA2A.Authority.Decision`'s own `@doc` examples were never wired into
  # ExUnit by any module, so the `canonical_json/1` example shipped unexecuted.
  # They run here, including the `verdict/1` example that is the primary
  # fail-open repro in miniature.
  doctest AshA2A.Authority.Decision

  @host_script Path.expand("support/hosts/authority_host.mjs", __DIR__)
  @conformance_spec Path.expand("support/hosts/authority_decision_conformance.json", __DIR__)

  @actuate "AshA2A.Test.Fixture.AuthorityProbe.actuate"
  @peek "AshA2A.Test.Fixture.AuthorityProbe.peek"

  setup do
    dir = Path.join(System.tmp_dir!(), "sa2a-failclosed-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    %{dir: dir, actuator_log: Path.join(dir, "independent_host_actuations.log")}
  end

  defp require_node! do
    unless match?({_out, 0}, System.cmd("node", ["--version"], stderr_to_stdout: true)) do
      # A named, visible failure -- never a silent substitution of a fake host.
      flunk("node is not available on this machine; the independent host cannot be exercised")
    end
  rescue
    ErlangError ->
      flunk("node is not available on this machine; the independent host cannot be exercised")
  end

  defp spec, do: @conformance_spec |> File.read!() |> JSON.decode!()

  defp repro_case(name) do
    spec()
    |> Map.fetch!("cases")
    |> Enum.find(&String.starts_with?(&1["name"], name))
    |> case do
      nil -> flunk("conformance spec has no case named #{name}")
      found -> found
    end
  end

  defp run_node_host(envelope, dir, actuator_log, label) do
    path = Path.join(dir, "envelope-#{label}.json")
    File.write!(path, Decision.canonical_json(envelope))

    {out, 0} = System.cmd("node", [@host_script, path, actuator_log], stderr_to_stdout: true)
    JSON.decode!(String.trim(out))
  end

  # ------------------------------------------------------------------
  # The three reproduced defects, each by its exact minimal input.
  # ------------------------------------------------------------------

  describe "DEFECT 1: absence must never bind" do
    test "the verifier's exact minimal input -- an authority with no fields against an envelope with no principal -- is REFUSED on both hosts and actuates nothing",
         %{dir: dir, actuator_log: actuator_log} do
      require_node!()

      %{"envelope" => envelope, "expect" => expect} = repro_case("REPRO-1 ")

      # This is literally `%{"consequence" => "external_do", "authority" => %{}}`
      # plus the version header. Before the fix: {:admitted, ...} and one real
      # actuator call.
      assert envelope["authority"] == %{}
      refute Map.has_key?(envelope, "principal")

      assert {:refused, %{code: :envelope_incomplete}} = Decision.verdict(envelope)

      result = run_node_host(envelope, dir, actuator_log, "d1")
      assert result["verdict"] == expect["verdict"]
      assert result["code"] == expect["code"]
      assert result["actuator_calls"] == 0
      refute File.exists?(actuator_log)
    end

    test "a blank-string principal and subject are absence with punctuation, not a match", %{
      dir: dir,
      actuator_log: actuator_log
    } do
      require_node!()

      %{"envelope" => envelope} = repro_case("REPRO-1c")
      assert String.trim(envelope["principal"]) == ""
      assert envelope["principal"] == envelope["authority"]["subject"]

      assert {:refused, %{code: :envelope_incomplete}} = Decision.verdict(envelope)
      assert run_node_host(envelope, dir, actuator_log, "d1c")["actuator_calls"] == 0
      refute File.exists?(actuator_log)
    end

    test "binds?/2 and expired?/2 now fail closed the SAME way on missing input", %{
      dir: dir,
      actuator_log: actuator_log
    } do
      require_node!()

      # `expired?` always failed closed on unparseable input; `binds?` failed
      # OPEN on missing input. The two are now consistent: both closed.
      for name <- ["REPRO-3b", "REPRO-3c", "unparseable expires_at"] do
        %{"envelope" => envelope, "expect" => expect} = repro_case(name)

        assert {:refused, %{code: :authority_mismatch}} = Decision.verdict(envelope),
               "#{name} must fail closed on the BEAM"

        result = run_node_host(envelope, dir, actuator_log, "closed-#{:erlang.phash2(name)}")
        assert result["code"] == expect["code"], "#{name} must fail closed on the node host"
        assert result["actuator_calls"] == 0
      end

      refute File.exists?(actuator_log)
    end
  end

  describe "DEFECT 2: the caller does not classify its own action" do
    test "the verifier's exact minimal input -- declaring observe on a consequence-bearing capability -- no longer skips the authority branch on either host",
         %{dir: dir, actuator_log: actuator_log} do
      require_node!()

      %{"envelope" => envelope, "expect" => expect} = repro_case("REPRO-2 ")

      assert envelope["consequence"] == "observe"
      assert envelope["authority"] == nil
      refute Map.has_key?(envelope, "capability_consequence")

      assert {:refused, %{code: :consequence_unattested}} = Decision.verdict(envelope)

      result = run_node_host(envelope, dir, actuator_log, "d2")
      assert result["verdict"] == expect["verdict"]
      assert result["code"] == expect["code"]
      assert result["actuator_calls"] == 0
      refute File.exists?(actuator_log)
    end

    test "a declared consequence that contradicts the DSL attestation is refused", %{
      dir: dir,
      actuator_log: actuator_log
    } do
      require_node!()

      %{"envelope" => envelope} = repro_case("REPRO-2b")
      assert envelope["consequence"] == "observe"
      assert envelope["capability_consequence"] == "external_do"

      assert {:refused, %{code: :consequence_unattested}} = Decision.verdict(envelope)
      assert run_node_host(envelope, dir, actuator_log, "d2b")["actuator_calls"] == 0
      refute File.exists?(actuator_log)
    end

    test "envelope/3 reads the consequence off the REAL resource DSL, exactly as CommandBus does" do
      principal = Identity.principal("operator-1")

      actuate_cmd =
        Command.new(@actuate, command_id: "attest-1", agent_id: "a", principal_id: principal)

      peek_cmd =
        Command.new(@peek, command_id: "attest-2", agent_id: "a", principal_id: principal)

      # The same values the real bus reads through AshA2A.Info.skill/2.
      assert {:ok, %{consequence: :external_do}} = AshA2A.Info.skill(AuthorityProbe, @actuate)
      assert {:ok, %{consequence: :observe}} = AshA2A.Info.skill(AuthorityProbe, @peek)

      attested_actuate = Decision.envelope(actuate_cmd, AuthorityProbe)
      attested_peek = Decision.envelope(peek_cmd, AuthorityProbe)

      assert attested_actuate["consequence"] == "external_do"
      assert attested_actuate["capability_consequence"] == "external_do"
      assert attested_peek["consequence"] == "observe"
      assert attested_peek["capability_consequence"] == "observe"

      # An attested external_do with no authority is refused for the real
      # reason, not misclassified away.
      assert {:refused, %{code: :authority_required}} = Decision.verdict(attested_actuate)
      # An attested observe needs no authority -- mirroring the bus.
      assert {:admitted, _} = Decision.verdict(attested_peek)

      # And a caller rewriting the declared consequence cannot undo the
      # attestation that came off the resource.
      forged = Map.put(attested_actuate, "consequence", "observe")
      assert {:refused, %{code: :consequence_unattested}} = Decision.verdict(forged)
    end

    test "an unresolvable capability produces no classification at all, and fails closed" do
      cmd =
        Command.new("AshA2A.Test.Fixture.AuthorityProbe.does_not_exist",
          command_id: "attest-3",
          agent_id: "a",
          principal_id: Identity.principal("operator-1")
        )

      envelope = Decision.envelope(cmd, AuthorityProbe)

      assert envelope["consequence"] == nil
      assert envelope["capability_consequence"] == nil
      assert {:refused, %{code: :consequence_unclassified}} = Decision.verdict(envelope)
    end
  end

  describe "DEFECT 3: the constrained party does not pick the clock" do
    test "the verifier's exact minimal input -- an authority expired in 2000 presented with evaluated_at in 1999 -- is REFUSED on both hosts",
         %{dir: dir, actuator_log: actuator_log} do
      require_node!()

      %{"envelope" => envelope, "expect" => expect} = repro_case("REPRO-3 ")

      assert envelope["evaluated_at"] == "1999-01-01T00:00:00Z"
      assert envelope["authority"]["expires_at"] == "2000-01-01T00:00:00Z"
      # The binding itself is perfect; only the clock was doctored.
      assert envelope["authority"]["subject"] == envelope["principal"]
      assert envelope["authority"]["capability_id"] == envelope["capability_id"]

      assert {:refused, %{code: :authority_mismatch}} = Decision.verdict(envelope)

      result = run_node_host(envelope, dir, actuator_log, "d3")
      assert result["verdict"] == expect["verdict"]
      assert result["code"] == expect["code"]
      assert result["actuator_calls"] == 0
      refute File.exists?(actuator_log)
    end

    test "expiry is judged against real host time, matching AshA2A.Authority.expired?/1" do
      principal = Identity.principal("operator-1")

      expired =
        Authority.new(principal, @actuate,
          token_id: "expired",
          expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
        )

      live =
        Authority.new(principal, @actuate,
          token_id: "live",
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        )

      # The real struct-level rule this portable rule now mirrors.
      assert Authority.expired?(expired)
      refute Authority.expired?(live)

      for {authority, expected} <- [{expired, :refused}, {live, :admitted}] do
        cmd =
          Command.new(@actuate,
            command_id: "clock-#{authority.token_id.value}",
            agent_id: "a",
            principal_id: principal,
            authority: authority
          )

        # Even when the caller names an instant comfortably before expiry,
        # the host's own clock decides.
        envelope =
          Decision.envelope(cmd, AuthorityProbe,
            evaluated_at: DateTime.add(DateTime.utc_now(), -86_400, :second)
          )

        case expected do
          :refused -> assert {:refused, %{code: :authority_mismatch}} = Decision.verdict(envelope)
          :admitted -> assert {:admitted, _} = Decision.verdict(envelope)
        end
      end
    end

    test "a caller's own evaluated_at can still close the gate, never hold it open" do
      principal = Identity.principal("operator-1")

      cmd =
        Command.new(@actuate,
          command_id: "clock-self-close",
          agent_id: "a",
          principal_id: principal,
          authority:
            Authority.new(principal, @actuate,
              token_id: "future",
              expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
            )
        )

      assert {:admitted, _} = Decision.verdict(Decision.envelope(cmd, AuthorityProbe))

      # Declaring an instant AFTER expiry is an admission against interest and
      # is honoured: max(host_now, evaluated_at) decides.
      self_closed =
        Decision.envelope(cmd, AuthorityProbe,
          evaluated_at: DateTime.add(DateTime.utc_now(), 7200, :second)
        )

      assert {:refused, %{code: :authority_mismatch}} = Decision.verdict(self_closed)
    end
  end

  # ------------------------------------------------------------------
  # The anti-drift pin: one specification, executed by both hosts.
  # ------------------------------------------------------------------

  describe "the two hosts are pinned to one shared specification" do
    test "every conformance case yields the same typed verdict on the BEAM and on the independent node host, and the node host's real actuator fires exactly on the ADMITTED cases",
         %{actuator_log: actuator_log} do
      require_node!()

      cases = Map.fetch!(spec(), "cases")
      assert length(cases) >= 19

      {out, 0} =
        System.cmd("node", [@host_script, "--spec", @conformance_spec, actuator_log],
          stderr_to_stdout: true
        )

      node_results =
        out
        |> String.trim()
        |> String.split("\n", trim: true)
        |> Enum.map(&JSON.decode!/1)
        |> Map.new(&{&1["name"], &1})

      assert map_size(node_results) == length(cases)

      for %{"name" => name, "envelope" => envelope, "expect" => expect} <- cases do
        beam =
          case Decision.verdict(envelope) do
            {:admitted, %{code: code}} ->
              %{"verdict" => "ADMITTED", "code" => to_string(code)}

            {:refused, %{code: code}} ->
              %{"verdict" => "REFUSED_AUTHORITY", "code" => to_string(code)}
          end

        node = Map.fetch!(node_results, name)

        assert beam == expect, "BEAM disagrees with the specification for #{inspect(name)}"

        assert %{"verdict" => beam["verdict"], "code" => beam["code"]} ==
                 %{"verdict" => node["verdict"], "code" => node["code"]},
               "the two hosts have drifted apart for #{inspect(name)}"
      end

      admitted = Enum.count(cases, &(&1["expect"]["verdict"] == "ADMITTED"))
      assert admitted >= 3, "the spec must contain positive controls, or every zero is vacuous"

      # The real actuator, on a real filesystem: exactly the ADMITTED cases
      # wrote, and nothing else did.
      lines = actuator_log |> File.read!() |> String.split("\n", trim: true)
      assert length(lines) == admitted

      refused_capabilities =
        cases
        |> Enum.reject(&(&1["expect"]["verdict"] == "ADMITTED"))
        |> Enum.map(&get_in(&1, ["envelope", "capability_id"]))
        |> Enum.reject(&is_nil/1)
        |> Enum.reject(fn capability ->
          Enum.any?(cases, fn c ->
            c["expect"]["verdict"] == "ADMITTED" and c["envelope"]["capability_id"] == capability
          end)
        end)

      for capability <- refused_capabilities do
        refute File.read!(actuator_log) =~ capability
      end
    end

    test "the specification preserves the pre-fix ADMITTED verdicts it was written to refute" do
      repros =
        spec()
        |> Map.fetch!("cases")
        |> Enum.filter(&Map.has_key?(&1, "was_before_fix"))

      # One per reproduced defect, each recording what it used to do.
      assert length(repros) == 3

      for repro <- repros do
        assert repro["was_before_fix"] == "ADMITTED, actuator_calls 1"
        assert repro["expect"]["verdict"] == "REFUSED_AUTHORITY"
      end
    end
  end
end


# --- SECTION 21: Original test/ash_a2a_authority_killer_negative_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.AuthorityKillerNegativeTest do
  @moduledoc """
  THE KILLER NEGATIVE FIXTURE (RFC-SA2A-001 S28, S29, S30, S60).

  One semantically valid operation walks the whole manufacturing chain --

      ADMITTED -> PLANNABLE -> SELECTED -> CONSTRUCTED -> REFUSED_AUTHORITY

  -- on TWO hosts that share no code, and BOTH terminate at
  `REFUSED_AUTHORITY` with **zero actuator calls**.

  This single fixture simultaneously demonstrates three S29 non-implications:

    * `SemanticValidity NOT=> Authority` -- the source really passes
      `AshA2A.Semantic.Admission.admit/2`;
    * `PlanValidity NOT=> Authority` -- the plan really passes
      `AshA2A.Planning.admit/2` and the package really passes
      `AshA2A.Semantic.ExecutionPackage.new/6`'s authority fence;
    * `GeneratedArtifact NOT=> DO` -- a real, content-addressed, fully
      constructed execution package is produced and still actuates nothing.

  ## The two hosts

    * **BEAM host**: the real `AshA2A.CommandBus` over a real Ash resource,
      with a real `AshA2A.Test.ActuatorCounter` GenServer as the actuator.
    * **Independent host**: `test/support/hosts/authority_host.mjs`, a real
      separate OS process (Node) that shares zero code with ash_a2a and
      re-derives the verdict from the canonical decision envelope alone. Its
      actuator is a real file append; the test asserts the file never comes
      into existence.

  Both actuators are REAL collaborators with real observable state (a process
  counter; a file on disk), not mocks. "Zero actuator calls" is therefore a
  measured fact, not an inference from a refusal tuple.

  ## Why the positive control is mandatory

  "The counter is 0" and "the file does not exist" are only evidence if both
  actuators demonstrably fire when they are supposed to. The first test in
  this module drives a correctly-authorized command through the same two
  hosts and asserts the counter reaches 1 and the file really is written.
  Without that control, every negative assertion below would be vacuous.
  """
  use ExUnit.Case

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Command, CommandBus, Identity}
  alias AshA2A.Authority.Decision
  alias AshA2A.Planning.Candidate
  alias AshA2A.Semantic.{Admission, ExecutionPackage, Ontology, PlanningIR, Source}
  alias AshA2A.Semantic.IR
  alias AshA2A.Test.ActuatorCounter
  alias AshA2A.Test.Fixture.AuthorityProbe

  @capability "AshA2A.Test.Fixture.AuthorityProbe.actuate"
  @scenario "The agent shall actuate the authority probe on behalf of the operator."
  @host_script Path.expand("support/hosts/authority_host.mjs", __DIR__)

  setup context do
    Application.put_env(:ash_a2a, :receipt_commit_retry_delays_ms, [1, 1])
    on_exit(fn -> Application.delete_env(:ash_a2a, :receipt_commit_retry_delays_ms) end)

    start_supervised!(ActuatorCounter)

    store = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: store})

    dir =
      Path.join(
        System.tmp_dir!(),
        "sa2a-authority-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    %{
      store_opts: [name: store],
      dir: dir,
      actuator_log: Path.join(dir, "independent_host_actuations.log"),
      test: context[:test]
    }
  end

  # --------------------------------------------------------------------
  # Stage 1-4 of the chain, built from real modules only.
  # --------------------------------------------------------------------

  defp admitted_ir do
    source = Source.new(@scenario)

    {:ok, candidate_ir} =
      IR.from_map(source.id, %{
        "authority" => "none",
        "goals" => [
          %{
            "id" => "goal-actuate",
            "kind" => "goal",
            "description" => "Actuate the authority probe",
            "source_quote" => "The agent shall actuate the authority probe"
          }
        ],
        "capabilities" => [
          %{
            "id" => "cap-actuate",
            "kind" => "capability",
            "description" => "probe actuation",
            "source_quote" => "actuate the authority probe"
          }
        ]
      })

    # ADMITTED: the real deterministic admission fence, not a hand-set flag.
    {:ok, ir} = Admission.admit(source, candidate_ir)
    {source, ir}
  end

  defp constructed_chain do
    {source, ir} = admitted_ir()
    assert ir.standing == :admitted
    assert ir.authority == :none

    # PLANNABLE
    {:ok, ontology} = Ontology.from_ir(ir)
    {:ok, planning_ir} = PlanningIR.from_ir(ir, ontology)

    # SELECTED: a real plan candidate whose projected capability really
    # resolves through the canonical capability index.
    candidate =
      Candidate.new(:test_planner, %{"capability_id" => @capability}, [@capability],
        formalism: :hddl_fond
      )

    {:ok, selected} = AshA2A.Planning.admit(AuthorityProbe, candidate)

    # CONSTRUCTED
    {:ok, package} = ExecutionPackage.new(source, ir, ontology, planning_ir, selected)

    %{source: source, ir: ir, selected: selected, package: package}
  end

  defp run_independent_host(envelope, dir, actuator_log, label) do
    envelope_path = Path.join(dir, "envelope-#{label}.json")
    File.write!(envelope_path, Decision.canonical_json(envelope))

    {out, 0} =
      System.cmd("node", [@host_script, envelope_path, actuator_log], stderr_to_stdout: true)

    JSON.decode!(String.trim(out))
  end

  defp node_available? do
    match?({_, 0}, System.cmd("node", ["--version"], stderr_to_stdout: true))
  rescue
    ErlangError -> false
  end

  # --------------------------------------------------------------------
  # POSITIVE CONTROL
  # --------------------------------------------------------------------

  test "CONTROL: both actuators really fire when authority IS present", %{
    store_opts: store_opts,
    dir: dir,
    actuator_log: actuator_log
  } do
    if not node_available?() do
      # A named, visible skip -- never a silent substitution of a mock host.
      flunk("node is not available on this machine; the independent host cannot be exercised")
    end

    principal = Identity.principal("operator-1")

    cmd =
      Command.new(@capability,
        command_id: "killer-control",
        agent_id: "agent-1",
        principal_id: principal,
        authority: Authority.new(principal, @capability, token_id: "control-token"),
        input: %{}
      )

    assert ActuatorCounter.count() == 0
    refute File.exists?(actuator_log)

    # BEAM host
    assert {:ok, receipt} =
             CommandBus.run(cmd, data_message(%{}), AuthorityProbe, store_opts: store_opts)

    assert receipt.status == :completed
    assert receipt.consequence == :external_do
    assert ActuatorCounter.count() == 1

    # Independent host
    envelope = Decision.envelope(cmd, AuthorityProbe)
    result = run_independent_host(envelope, dir, actuator_log, "control")

    assert result["verdict"] == "ADMITTED"
    assert result["actuator_calls"] == 1
    assert File.exists?(actuator_log)
    assert File.read!(actuator_log) =~ @capability

    # And the two hosts agree on the decision INPUT, byte for byte.
    assert result["envelope_digest"] == Decision.digest(envelope)
  end

  # --------------------------------------------------------------------
  # THE KILLER NEGATIVE
  # --------------------------------------------------------------------

  test "ADMITTED -> PLANNABLE -> SELECTED -> CONSTRUCTED -> REFUSED_AUTHORITY on both the BEAM host and an independent host, with ZERO actuator calls (SemanticValidity NOT=> Authority, PlanValidity NOT=> Authority, GeneratedArtifact NOT=> DO)",
       %{store_opts: store_opts, dir: dir, actuator_log: actuator_log} do
    if not node_available?() do
      flunk("node is not available on this machine; the independent host cannot be exercised")
    end

    chain = constructed_chain()

    # --- the chain really did get all the way to CONSTRUCTED ------------
    assert chain.ir.standing == :admitted
    assert chain.selected.admitted_skills != []
    assert %ExecutionPackage{standing: :candidate, authority: :none} = chain.package
    assert chain.package.fingerprint =~ ~r/^[0-9a-f]{64}$/

    # ... and every stage's ceiling is `authority: :none`. Nothing along the
    # manufacturing chain can raise it; that is the S28 ceiling.
    assert chain.ir.authority == :none
    assert chain.selected.authority == :none
    assert chain.package.semantic_ir.authority == :none
    assert chain.package.plan_candidate.authority == :none

    principal = Identity.principal("operator-1")

    cmd =
      Command.new(@capability,
        command_id: "killer-refused",
        agent_id: "agent-1",
        principal_id: principal,
        # No authority. Everything else about this request is impeccable.
        authority: nil,
        input: %{},
        metadata: %{
          execution_package: chain.package.fingerprint,
          plan: chain.selected.fingerprint,
          semantic_source: chain.source.id
        }
      )

    assert ActuatorCounter.count() == 0
    refute File.exists?(actuator_log)

    # --- BEAM host terminates at REFUSED_AUTHORITY ----------------------
    assert {:error, %{code: :authority_required, detail: "authority_required"}} =
             CommandBus.run(cmd, data_message(%{}), AuthorityProbe, store_opts: store_opts)

    assert ActuatorCounter.count() == 0

    # --- independent host terminates at REFUSED_AUTHORITY ---------------
    envelope = Decision.envelope(cmd, AuthorityProbe)
    result = run_independent_host(envelope, dir, actuator_log, "refused")

    assert result["host"] == "node"
    assert result["verdict"] == "REFUSED_AUTHORITY"
    assert result["code"] == "authority_required"
    assert result["actuator_calls"] == 0

    # --- ZERO actuator calls, on both hosts, measured ---------------------
    assert ActuatorCounter.count() == 0
    refute File.exists?(actuator_log)

    # --- both hosts saw the same decision input -------------------------
    assert result["envelope_digest"] == Decision.digest(envelope)
  end

  test "the same constructed package presented with a MISMATCHED authority also terminates at REFUSED_AUTHORITY on both hosts with zero actuation",
       %{store_opts: store_opts, dir: dir, actuator_log: actuator_log} do
    if not node_available?() do
      flunk("node is not available on this machine; the independent host cannot be exercised")
    end

    chain = constructed_chain()
    assert %ExecutionPackage{authority: :none} = chain.package

    principal = Identity.principal("operator-1")

    cmd =
      Command.new(@capability,
        command_id: "killer-mismatch",
        agent_id: "agent-1",
        principal_id: principal,
        # Real authority -- for a DIFFERENT principal. Presenting someone
        # else's valid grant is not authority.
        authority:
          Authority.new(Identity.principal("someone-else"), @capability,
            token_id: "borrowed-token"
          ),
        input: %{},
        metadata: %{execution_package: chain.package.fingerprint}
      )

    assert {:error, %{code: :authority_mismatch}} =
             CommandBus.run(cmd, data_message(%{}), AuthorityProbe, store_opts: store_opts)

    envelope = Decision.envelope(cmd, AuthorityProbe)
    result = run_independent_host(envelope, dir, actuator_log, "mismatch")

    assert result["verdict"] == "REFUSED_AUTHORITY"
    assert result["code"] == "authority_mismatch"
    assert result["actuator_calls"] == 0

    assert ActuatorCounter.count() == 0
    refute File.exists?(actuator_log)
  end

  test "an EXPIRED authority terminates at REFUSED_AUTHORITY identically on both hosts, each deciding against its OWN real clock (the constrained party does not pick the clock)",
       %{store_opts: store_opts, dir: dir, actuator_log: actuator_log} do
    if not node_available?() do
      flunk("node is not available on this machine; the independent host cannot be exercised")
    end

    principal = Identity.principal("operator-1")
    expires_at = DateTime.add(DateTime.utc_now(), -60, :second)

    cmd =
      Command.new(@capability,
        command_id: "killer-expired",
        agent_id: "agent-1",
        principal_id: principal,
        authority:
          Authority.new(principal, @capability,
            token_id: "expired-token",
            expires_at: expires_at
          ),
        input: %{}
      )

    assert {:error, %{code: :authority_mismatch}} =
             CommandBus.run(cmd, data_message(%{}), AuthorityProbe, store_opts: store_opts)

    # The independent host decides expiry from its OWN real clock, the same
    # way `AshA2A.Authority.expired?/1` does on the BEAM. It deliberately does
    # NOT take the instant from the envelope it is judging: that let the party
    # being constrained choose the clock, and was a reproduced fail-open
    # defect (see `AshA2A.AuthorityDecisionFailClosedTest`). The envelope's
    # own `evaluated_at` is still consulted, but only when it is LATER than
    # expiry -- it can close the gate further, never hold it open.
    envelope = Decision.envelope(cmd, AuthorityProbe)
    result = run_independent_host(envelope, dir, actuator_log, "expired")

    assert result["verdict"] == "REFUSED_AUTHORITY"
    assert result["code"] == "authority_mismatch"
    assert result["actuator_calls"] == 0
    assert ActuatorCounter.count() == 0
    refute File.exists?(actuator_log)
  end
end


# --- SECTION 22: Original test/ash_a2a_authority_non_implications_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.AuthorityNonImplicationsTest do
  @moduledoc """
  RFC-SA2A-001 S29: the eight non-implications, each as its own individually
  named, executable falsifier against the REAL `AshA2A.CommandBus` and the
  REAL `AshA2A.Authority` -- no mocks, no stubbed collaborators, real Ash
  resources, real receipt store, real counting actuator.

      Identity           NOT=> Authority
      Authentication     NOT=> Authority
      Capability         NOT=> Authority
      TaskAssignment     NOT=> Authority
      PlanValidity       NOT=> Authority
      Proof              NOT=> Authority
      ModelConfidence    NOT=> Authority
      AgentCardDeclaration NOT=> Authority

  Each test builds the STRONGEST available form of its antecedent (a real
  verified transport identity, a capability that really resolves through
  `AshA2A.Info`, a plan that really passes `AshA2A.Planning.admit/2`, a proof
  digest this test really verifies, and so on), then asserts the bus still
  refuses AND that the real actuator count is still 0.

  Several of these hold structurally in the pre-existing code
  (`CommandBus.admit/2` consults only `AshA2A.Authority.admits?/2`, which
  compares subject and capability and nothing else). That is exactly why they
  are written down here: an implicit property nobody asserts is one refactor
  away from silently disappearing. See the "already held / newly enforced"
  notes on each test.
  """
  use ExUnit.Case

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Command, CommandBus, Identity, ReceiptStore}
  alias AshA2A.Authority.Decision
  alias AshA2A.Planning.Candidate
  alias AshA2A.Semantic.{Admission, ExecutionPackage, Ontology, PlanningIR, Source}
  alias AshA2A.Semantic.IR
  alias AshA2A.Test.ActuatorCounter
  alias AshA2A.Test.Fixture.AuthorityProbe

  @capability "AshA2A.Test.Fixture.AuthorityProbe.actuate"
  @observe_capability "AshA2A.Test.Fixture.AuthorityProbe.peek"

  setup do
    Application.put_env(:ash_a2a, :receipt_commit_retry_delays_ms, [1, 1])
    on_exit(fn -> Application.delete_env(:ash_a2a, :receipt_commit_retry_delays_ms) end)

    start_supervised!(ActuatorCounter)

    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: name})
    %{store_opts: [name: name]}
  end

  defp run(command, store_opts) do
    CommandBus.run(command, data_message(%{}), AuthorityProbe, store_opts: store_opts)
  end

  defp command(opts) do
    Command.new(
      Keyword.get(opts, :capability_id, @capability),
      Keyword.merge(
        [
          agent_id: "agent-under-test",
          principal_id: "principal-under-test",
          input: %{}
        ],
        opts
      )
      |> Keyword.delete(:capability_id)
    )
  end

  # --------------------------------------------------------------------
  # Control: the actuator and the whole dispatch path really do work.
  # Without this, every "count == 0" assertion below would be vacuous.
  # --------------------------------------------------------------------

  test "CONTROL: a correctly authorized command really does reach the actuator (so count==0 elsewhere is a real observation)",
       %{store_opts: store_opts} do
    principal = Identity.principal("principal-under-test")

    cmd =
      command(
        command_id: "control-admitted",
        authority: Authority.new(principal, @capability, token_id: "control-token")
      )

    assert ActuatorCounter.count() == 0
    assert {:ok, receipt} = run(cmd, store_opts)
    assert receipt.status == :completed
    assert receipt.consequence == :external_do

    # Real state, not "was it called": the counter really advanced.
    assert ActuatorCounter.count() == 1
  end

  # --------------------------------------------------------------------
  # 1. Identity NOT=> Authority
  # --------------------------------------------------------------------

  test "Identity NOT=> Authority: a real, well-formed principal Identity on a real consequence-bearing capability is refused with zero actuation",
       %{store_opts: store_opts} do
    # ALREADY HELD structurally (`CommandBus.admit/2` has an
    # `:authority_required` clause); newly made an explicit falsifier here.
    principal = Identity.principal("principal-under-test")
    assert %Identity{kind: :principal, value: "principal-under-test"} = principal

    cmd = command(command_id: "identity-1", principal_id: principal, authority: nil)

    assert {:error, %{code: :authority_required}} = run(cmd, store_opts)
    assert ActuatorCounter.count() == 0
    assert :error = ReceiptStore.Memory.fetch(cmd.command_id, store_opts)
  end

  # --------------------------------------------------------------------
  # 2. Authentication NOT=> Authority
  # --------------------------------------------------------------------

  test "Authentication NOT=> Authority: a transport-VERIFIED identity carrying authority for one capability cannot act on another",
       %{store_opts: store_opts} do
    # This is the strongest available form of "authenticated": the exact
    # constructor the A2A adapter uses for an identity `AshA2A.Protocol.Plug.Auth` has
    # already verified. It really does produce `source: :transport_verified`.
    authenticated = Authority.from_verified_identity("principal-under-test", @observe_capability)

    assert %Authority{source: :transport_verified} = authenticated
    assert authenticated.subject == Identity.principal("principal-under-test")

    cmd = command(command_id: "authn-1", authority: authenticated)

    # Authenticated, and authenticated *for a capability on this very
    # resource* -- still refused for the consequence-bearing one.
    assert {:error, %{code: :authority_mismatch}} = run(cmd, store_opts)
    assert ActuatorCounter.count() == 0
  end

  # --------------------------------------------------------------------
  # 3. Capability NOT=> Authority
  # --------------------------------------------------------------------

  test "Capability NOT=> Authority: a capability that really resolves through AshA2A.Info is still refused without authority",
       %{store_opts: store_opts} do
    # The antecedent is real and checked, not assumed: the capability
    # genuinely resolves to a real skill over a real compiled resource.
    assert {:ok, skill} = AshA2A.Info.skill(AuthorityProbe, @capability)
    assert skill.consequence == :external_do
    assert skill.resource == AuthorityProbe

    cmd = command(command_id: "capability-1", authority: nil)

    assert {:error, %{code: :authority_required}} = run(cmd, store_opts)
    assert ActuatorCounter.count() == 0
  end

  # --------------------------------------------------------------------
  # 4. TaskAssignment NOT=> Authority
  # --------------------------------------------------------------------

  test "TaskAssignment NOT=> Authority: a command bound to a real task identity is refused exactly as an unassigned one is",
       %{store_opts: store_opts} do
    task = Identity.task("task-really-assigned-to-this-agent")
    cmd = command(command_id: "task-1", task_id: task, authority: nil)

    assert cmd.task_id == task
    assert {:error, %{code: :authority_required}} = run(cmd, store_opts)
    assert ActuatorCounter.count() == 0

    # And assignment does not even perturb the refusal: the decision is
    # byte-identical with and without the task binding.
    without_task = command(command_id: "task-2", authority: nil)

    assert Decision.verdict(Decision.envelope(cmd, AuthorityProbe)) ==
             Decision.verdict(Decision.envelope(without_task, AuthorityProbe))
  end

  # --------------------------------------------------------------------
  # 5. PlanValidity NOT=> Authority
  # --------------------------------------------------------------------

  test "PlanValidity NOT=> Authority: a plan that really passes AshA2A.Planning.admit/2 confers nothing on the bus",
       %{store_opts: store_opts} do
    # A genuinely admitted plan candidate over the canonical capability --
    # `Planning.admit/2` resolves every projected capability id through the
    # real capability index and refuses noncanonical ones.
    candidate =
      Candidate.new(:test_planner, %{"capability_id" => @capability}, [@capability],
        formalism: :hddl_fond
      )

    assert {:ok, admitted} = AshA2A.Planning.admit(AuthorityProbe, candidate)
    assert [%AshA2A.Skill{}] = admitted.admitted_skills

    # The admitted plan's own standing is the ceiling: candidate, authority
    # :none. Planning cannot raise it -- that is structurally enforced.
    assert admitted.standing == :candidate
    assert admitted.authority == :none

    cmd = command(command_id: "plan-1", authority: nil, metadata: %{plan: admitted.fingerprint})

    assert {:error, %{code: :authority_required}} = run(cmd, store_opts)
    assert ActuatorCounter.count() == 0
  end

  test "PlanValidity NOT=> Authority: a fully CONSTRUCTED semantic execution package is still authority: :none",
       %{store_opts: store_opts} do
    package = constructed_package()

    # Real, constructed, content-addressed manufacturing output ...
    assert %ExecutionPackage{standing: :candidate, authority: :none} = package
    assert package.fingerprint =~ ~r/^[0-9a-f]{64}$/

    # ... and it still buys exactly nothing at the consequence boundary.
    cmd =
      command(
        command_id: "package-1",
        authority: nil,
        metadata: %{execution_package: package.fingerprint}
      )

    assert {:error, %{code: :authority_required}} = run(cmd, store_opts)
    assert ActuatorCounter.count() == 0
  end

  # --------------------------------------------------------------------
  # 6. Proof NOT=> Authority
  # --------------------------------------------------------------------

  test "Proof NOT=> Authority: a cryptographic proof this test independently VERIFIES does not admit the command",
       %{store_opts: store_opts} do
    payload = "authority-probe-actuation-request"

    proof =
      payload
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    # The proof is real and really checks out -- the antecedent is genuinely
    # true here, not a placeholder string.
    assert proof ==
             :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)

    assert String.length(proof) == 64

    cmd =
      command(
        command_id: "proof-1",
        authority: nil,
        metadata: %{proof: proof, proof_algorithm: "sha256", proof_payload: payload}
      )

    assert {:error, %{code: :authority_required}} = run(cmd, store_opts)
    assert ActuatorCounter.count() == 0
  end

  # --------------------------------------------------------------------
  # 7. ModelConfidence NOT=> Authority
  # --------------------------------------------------------------------

  test "ModelConfidence NOT=> Authority: confidence 1.0 is refused identically to confidence 0.0",
       %{store_opts: store_opts} do
    certain = command(command_id: "confidence-1", authority: nil, metadata: %{confidence: 1.0})
    unsure = command(command_id: "confidence-2", authority: nil, metadata: %{confidence: 0.0})

    assert {:error, %{code: :authority_required}} = run(certain, store_opts)
    assert {:error, %{code: :authority_required}} = run(unsure, store_opts)
    assert ActuatorCounter.count() == 0

    # Confidence is not even an input to the decision: it does not appear in
    # the canonical decision envelope at all, so the two commands -- which
    # differ ONLY in stated confidence -- are literally the same decision
    # input, byte for byte.
    at = ~U[2026-01-01 00:00:00Z]

    assert certain.metadata != unsure.metadata

    assert Decision.digest(Decision.envelope(certain, AuthorityProbe, evaluated_at: at)) ==
             Decision.digest(Decision.envelope(unsure, AuthorityProbe, evaluated_at: at))
  end

  # --------------------------------------------------------------------
  # 8. AgentCardDeclaration NOT=> Authority
  # --------------------------------------------------------------------

  test "AgentCardDeclaration NOT=> Authority: a skill really published on the real A2A agent card is still refused",
       %{store_opts: store_opts} do
    card = AshA2A.Info.agent_card(AuthorityProbe)

    # The antecedent is real: the capability genuinely is advertised.
    declared_ids = Enum.map(card.skills, & &1.id)
    assert @capability in declared_ids

    cmd = command(command_id: "card-1", authority: nil)

    assert {:error, %{code: :authority_required}} = run(cmd, store_opts)
    assert ActuatorCounter.count() == 0
  end

  # --------------------------------------------------------------------
  # Pinning: the portable decision function must not drift from the bus.
  # --------------------------------------------------------------------

  describe "AshA2A.Authority.Decision is pinned to the real CommandBus" do
    test "every non-implication case yields the same typed outcome from the bus and from the portable evaluator",
         %{store_opts: store_opts} do
      principal = Identity.principal("principal-under-test")

      cases = [
        {:authority_required, command(command_id: "pin-1", authority: nil)},
        {:authority_mismatch,
         command(
           command_id: "pin-2",
           authority: Authority.new(principal, @observe_capability, token_id: "pin-wrong-cap")
         )},
        {:authority_mismatch,
         command(
           command_id: "pin-3",
           authority:
             Authority.new(Identity.principal("someone-else"), @capability,
               token_id: "pin-wrong-subject"
             )
         )},
        {:admitted,
         command(
           command_id: "pin-4",
           authority: Authority.new(principal, @capability, token_id: "pin-ok")
         )}
      ]

      for {expected, cmd} <- cases do
        bus = run(cmd, store_opts)
        portable = Decision.verdict(Decision.envelope(cmd, AuthorityProbe))

        case expected do
          :admitted ->
            assert {:ok, %AshA2A.Receipt{}} = bus
            assert {:admitted, %{code: :authority_admitted}} = portable

          code ->
            assert {:error, %{code: ^code}} = bus
            assert {:refused, %{code: ^code}} = portable
        end
      end
    end

    test "an observe-consequence capability needs no authority on both the bus and the portable evaluator",
         %{store_opts: store_opts} do
      cmd = command(command_id: "pin-observe", capability_id: @observe_capability, authority: nil)

      assert {:ok, receipt} = run(cmd, store_opts)
      assert receipt.consequence == :observe
      assert {:admitted, _} = Decision.verdict(Decision.envelope(cmd, AuthorityProbe))
    end
  end

  # --------------------------------------------------------------------

  defp constructed_package do
    source = Source.new("The agent shall actuate the authority probe.")

    # Real admission, not a hand-set `standing: :admitted`: IR.from_map/2
    # builds a genuine :candidate IR and Admission.admit/2 runs its full
    # check chain for real, so the returned IR carries a real
    # AshA2A.Semantic.IrAdmissionSeal-minted seal (see that module's docs).
    payload = %{
      "authority" => "none",
      "goals" => [
        %{
          "id" => "goal-1",
          "kind" => "goal",
          "description" => "Actuate the probe",
          "source_quote" => "The agent shall actuate the authority probe."
        }
      ]
    }

    {:ok, candidate_ir} = IR.from_map(source.id, payload)
    {:ok, ir} = Admission.admit(source, candidate_ir)

    {:ok, ontology} = Ontology.from_ir(ir)
    {:ok, planning_ir} = PlanningIR.from_ir(ir, ontology)

    candidate =
      Candidate.new(:test_planner, %{"capability_id" => @capability}, [@capability],
        formalism: :hddl_fond
      )

    {:ok, package} = ExecutionPackage.new(source, ir, ontology, planning_ir, candidate)
    package
  end
end

