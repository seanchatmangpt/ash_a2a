# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.TransportCourt.Probe do
  @moduledoc false
  use Ash.Resource,
    domain: AshA2A.TransportCourt.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  actions do
    action :whoami, :map do
      run(fn _input, context ->
        subject =
          case context.actor do
            %{sub: sub} -> sub
            other when is_binary(other) -> other
            _ -> nil
          end

        {:ok, %{"subject" => subject}}
      end)
    end

    action :pair, :map do
      argument(:left, :string, allow_nil?: false)
      argument(:right, :string, allow_nil?: false)

      run(fn input, context ->
        {:ok,
         %{
           "left" => input.arguments.left,
           "right" => input.arguments.right,
           "subject" => context.actor && context.actor[:sub]
         }}
      end)
    end

    action :slow, :map do
      argument(:ms, :integer, allow_nil?: false)

      run(fn input, _context ->
        Process.sleep(input.arguments.ms)
        {:ok, %{"slept" => input.arguments.ms}}
      end)
    end

    action :ctx, :map do
      run(fn _input, context ->
        source = context.source_context || %{}
        client = Map.get(source, :a2a_client_context, %{})

        {:ok,
         %{
           "top_level_is_admin" => Map.get(source, "is_admin"),
           "client_is_admin" => Map.get(client, "is_admin")
         }}
      end)
    end
  end

  a2a do
    skill(:whoami, :whoami, consequence: :observe)
    skill(:pair, :pair, consequence: :observe)
    skill(:slow, :slow, consequence: :observe)
    skill(:ctx, :ctx, consequence: :observe)
  end
end

defmodule AshA2A.TransportCourt.Domain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.TransportCourt.Probe)
  end
end

defmodule AshA2A.TransportCourt.Agent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.TransportCourt.Probe,
    name: "transport_court_agent",
    require_authenticated_caller: true
end

defmodule AshA2A.TransportCourt.InlineAgent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.TransportCourt.Probe,
    name: "transport_court_inline_agent",
    require_authenticated_caller: true,
    execution: [mode: :inline]
end

defmodule AshA2A.TransportCourt.BusyAgent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.TransportCourt.Probe,
    name: "transport_court_busy_agent",
    require_authenticated_caller: true,
    execution: [max_in_flight: 1]
end

defmodule AshA2A.TransportCourt.RateAgent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.TransportCourt.Probe,
    name: "transport_court_rate_agent",
    require_authenticated_caller: true,
    execution: [rate_limit: {1, 60_000}]
end

defmodule AshA2A.TransportCourt.PublicAgent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.TransportCourt.Probe,
    name: "transport_court_public_agent",
    require_authenticated_caller: true,
    public_skills: [:whoami]
end

defmodule AshA2A.TransportCourt.CrashAgent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.TransportCourt.Probe,
    name: "transport_court_crash_agent",
    require_authenticated_caller: false

  # A handler bug: raises for "raise", kills its own process for "kill".
  @impl AshA2A.Protocol.Agent
  def handle_message(%AshA2A.Protocol.Message{} = message, context) do
    case AshA2A.Protocol.Message.text(message) do
      "raise" -> raise "SELECT secret_column FROM credentials -- internal detail"
      "kill" -> Process.exit(self(), :kill)
      _ -> super(message, context)
    end
  end
end

defmodule AshA2A.TransportCourt.MessageAgent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.TransportCourt.Probe,
    name: "transport_court_message_agent",
    require_authenticated_caller: true

  # Thin TCK-SUT-style wrapper: skill metadata "dm" replies out-of-band
  # (`{:message, parts}` — a bare Message, no task); "file-artifact" replies
  # with a typed file part. Everything else falls through to the real
  # AshA2A dispatch.
  @impl AshA2A.Protocol.Agent
  def handle_message(%AshA2A.Protocol.Message{} = message, context) do
    case message.metadata["skill"] do
      "dm" ->
        {:message, [AshA2A.Protocol.Part.Text.new("Direct message response")]}

      "file-artifact" ->
        file =
          AshA2A.Protocol.FileContent.from_bytes("tck",
            name: "output.txt",
            mime_type: "text/plain"
          )

        {:reply, [AshA2A.Protocol.Part.File.new(file)]}

      _ ->
        super(message, context)
    end
  end
end

defmodule AshA2A.TransportCourt.Pipeline do
  @moduledoc false
  @behaviour Plug

  @schemes %{"bearer_auth" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}}

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    {auth?, opts} = Keyword.pop(opts, :auth?, true)

    conn =
      if auth?,
        do: AshA2A.Protocol.Plug.Auth.call(conn, AshA2A.Protocol.Plug.Auth.init(schemes: @schemes, verify: &verify/3)),
        else: conn

    if conn.halted,
      do: conn,
      else: AshA2A.Transport.Plug.call(conn, AshA2A.Transport.Plug.init(opts))
  end

  # Identities deliberately carry a raw token and a volatile claim: neither
  # may ever surface on the wire or in the owner key.
  def verify("bearer_auth", "tok-alice", _conn),
    do: {:ok, %{sub: "alice", token: "tok-alice-SECRET", exp: 1}}

  def verify("bearer_auth", "tok-bob", _conn),
    do: {:ok, %{sub: "bob", token: "tok-bob-SECRET", exp: 2}}

  def verify(_scheme, _credential, _conn), do: {:error, "invalid token"}
end

defmodule AshA2A.TransportCourtTest do
  @moduledoc """
  Chicago court for the transport lane (SEC-01/02/03/05/08/11, TQ-05,
  CONF-06/09): real `AshA2A.Agent` GenServers, real `AshA2A.Protocol.Plug.Auth` +
  `AshA2A.Transport.Plug` behind a real Bandit listener on an ephemeral
  port, real HTTP via Req. No mocks.
  """
  use ExUnit.Case, async: false

  alias AshA2A.TransportCourt

  @error_info_type "type.googleapis.com/google.rpc.ErrorInfo"
  @a2a_domain "a2a-protocol.org"

  # v1.0 registry ErrorInfo shapes (AshA2A.Protocol.JSONRPC.Error): -32001 is
  # TASK_NOT_FOUND (also the owner-scope answer: a foreign task is
  # indistinguishable from a missing one), -32002 is TASK_NOT_CANCELABLE.
  defp task_not_found_info,
    do: %{"@type" => @error_info_type, "domain" => @a2a_domain, "reason" => "TASK_NOT_FOUND"}

  defp task_not_cancelable_info,
    do: %{"@type" => @error_info_type, "domain" => @a2a_domain, "reason" => "TASK_NOT_CANCELABLE"}

  defp start_http!(agent, extra \\ []) do
    name = :"#{inspect(agent)}_#{System.unique_integer([:positive])}"
    pid = start_supervised!({agent, name: name}, id: name)

    plug_opts = [agent: name, base_url: "http://127.0.0.1/a2a"] ++ extra

    server =
      start_supervised!(
        {Bandit,
         plug: {TransportCourt.Pipeline, plug_opts},
         port: 0,
         ip: {127, 0, 0, 1},
         startup_log: false},
        id: {:bandit, name}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{agent: pid, name: name, url: "http://127.0.0.1:#{port}"}
  end

  defp rpc(url, method, params, token) do
    headers = if token, do: [{"authorization", "Bearer " <> token}], else: []

    Req.post!(url,
      json: %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params},
      headers: headers,
      retry: false,
      receive_timeout: 15_000,
      decode_body: false
    )
  end

  defp rpc_json(url, method, params, token) do
    url |> rpc(method, params, token) |> Map.fetch!(:body) |> Jason.decode!()
  end

  defp message(skill, data, extra_metadata \\ %{}) do
    msg = %{
      AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(data)])
      | metadata: Map.put(extra_metadata, "skill", skill)
    }

    {:ok, json} = AshA2A.Protocol.JSON.encode(msg)
    json
  end

  defp send_msg(url, skill, data, token, extra \\ %{}) do
    rpc_json(url, "message/send", %{"message" => message(skill, data, extra)}, token)
  end

  defp artifact_data(%{"result" => %{"task" => task}}), do: artifact_data(task)

  defp artifact_data(%{"artifacts" => [%{"parts" => [%{"data" => data} | _]} | _]}), do: data

  describe "SEC-01 task ownership over real HTTP with two real bearer principals" do
    setup do
      start_http!(TransportCourt.Agent)
    end

    test "B cannot continue, read, cancel or list A's input_required task; A can", %{url: url} do
      a = send_msg(url, "pair", %{"left" => "L"}, "tok-alice")
      assert %{"result" => %{"task" => %{"id" => task_id, "status" => %{"state" => state}}}} = a
      assert state == "TASK_STATE_INPUT_REQUIRED"

      # A paused (non-terminal) task still holds the verified auth in memory;
      # it must never be echoed onto the wire.
      refute Jason.encode!(a) =~ "SECRET"

      # B continues A's task: refused, indistinguishable from unknown id.
      cont = %{AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(%{"right" => "R"})]) | task_id: task_id}
      {:ok, cont} = AshA2A.Protocol.JSON.encode(%{cont | metadata: %{"skill" => "pair"}})
      b = rpc_json(url, "message/send", %{"message" => cont}, "tok-bob")

      # v1.0 registry: -32001 carries a TASK_NOT_FOUND google.rpc.ErrorInfo.
      not_found = task_not_found_info()
      assert %{"error" => %{"code" => -32001, "data" => [^not_found]}} = b

      # B cannot read / cancel / list it.
      assert %{"error" => %{"code" => -32001, "data" => [^not_found]}} =
               rpc_json(url, "tasks/get", %{"id" => task_id}, "tok-bob")

      assert %{"error" => %{"code" => -32001, "data" => [^not_found]}} =
               rpc_json(url, "tasks/cancel", %{"id" => task_id}, "tok-bob")

      %{"result" => %{"tasks" => b_tasks}} = rpc_json(url, "tasks/list", %{}, "tok-bob")
      refute Enum.any?(b_tasks, &(&1["id"] == task_id))

      # A's task is untouched by B's attempts, and A can list and finish it.
      assert %{"result" => %{"status" => %{"state" => "TASK_STATE_INPUT_REQUIRED"}}} =
               rpc_json(url, "tasks/get", %{"id" => task_id}, "tok-alice")

      %{"result" => %{"tasks" => a_tasks}} = rpc_json(url, "tasks/list", %{}, "tok-alice")
      assert Enum.any?(a_tasks, &(&1["id"] == task_id))

      done = rpc_json(url, "message/send", %{"message" => cont}, "tok-alice")

      assert %{"result" => %{"task" => %{"status" => %{"state" => "TASK_STATE_COMPLETED"}}}} =
               done

      assert %{"left" => "L", "right" => "R", "subject" => "alice"} = artifact_data(done)
    end

    test "task ids are 128-bit CSPRNG ids and credentials never echo onto the wire", %{url: url} do
      resp = rpc(url, "message/send", %{"message" => message("whoami", %{})}, "tok-alice")
      body = Jason.decode!(resp.body)
      %{"result" => %{"task" => %{"id" => id} = task}} = body
      assert "tsk-" <> suffix = id
      assert byte_size(suffix) == 22
      assert {:ok, <<_::128>>} = Base.url_decode64(suffix, padding: false)

      refute resp.body =~ "SECRET"
      refute Map.has_key?(task["metadata"] || %{}, "a2a.auth")
      refute resp.body =~ "ash_a2a.owner"

      get = rpc(url, "tasks/get", %{"id" => id}, "tok-alice")
      refute get.body =~ "SECRET"
    end

    test "a caller cannot forge a2a.auth through params.metadata", %{url: url} do
      forged = %{"a2a.auth" => %{"identity" => %{"sub" => "alice"}}}

      body =
        rpc_json(
          url,
          "message/send",
          %{"message" => message("whoami", %{}), "metadata" => forged},
          "tok-bob"
        )

      assert %{"subject" => "bob"} = artifact_data(body)
    end
  end

  describe "SEC-02 malformed requests fail only their own task" do
    setup do
      start_http!(TransportCourt.Agent)
    end

    test "non-map metadata, non-map context and non-map data are typed refusals; agent survives",
         %{url: url, agent: agent} do
      base = message("whoami", %{})

      bad_metadata =
        rpc_json(url, "message/send", %{"message" => Map.put(base, "metadata", [1])}, "tok-alice")

      bad_context =
        rpc_json(
          url,
          "message/send",
          %{"message" => Map.put(base, "metadata", %{"skill" => "whoami", "context" => "x"})},
          "tok-alice"
        )

      for body <- [bad_metadata, bad_context] do
        assert %{
                 "result" => %{
                   "task" => %{"status" => %{"state" => "TASK_STATE_FAILED", "message" => msg}}
                 }
               } =
                 body

        text = msg |> Map.fetch!("parts") |> hd() |> Map.fetch!("text")
        assert text =~ ":invalid_metadata" or text =~ ":invalid_context"
      end

      assert Process.alive?(agent)
      assert %{"subject" => "alice"} = artifact_data(send_msg(url, "whoami", %{}, "tok-alice"))
    end

    test "oversized client context is refused with a typed bound", %{url: url} do
      big = %{"blob" => String.duplicate("x", 20_000)}
      body = send_msg(url, "whoami", %{}, "tok-alice", %{"context" => big})

      assert %{
               "result" => %{
                 "task" => %{"status" => %{"state" => "TASK_STATE_FAILED", "message" => msg}}
               }
             } =
               body

      assert msg |> Map.fetch!("parts") |> hd() |> Map.fetch!("text") =~ ":context_too_large"
    end

    test "non-map Data part data is refused before dispatch" do
      message = %AshA2A.Protocol.Message{
        role: :user,
        parts: [%AshA2A.Protocol.Part.Data{data: "x"}],
        metadata: %{"skill" => "whoami"}
      }

      assert {:error, %{code: :invalid_input}} =
               AshA2A.Agent.__dispatch__(TransportCourt.Probe, message, %{}, [])
    end

    test "an exception inside dispatch becomes a typed internal_error with a ref" do
      message = %{AshA2A.Protocol.Message.new_user("hi") | metadata: %{"skill" => "whoami"}}

      assert {:error, %{code: :internal_error, ref: ref}} =
               AshA2A.Agent.__dispatch__(:not_an_ash_module, message, %{}, [])

      assert is_binary(ref) and byte_size(ref) == 16
    end
  end

  describe "SEC-02/SEC-08 handler crashes are isolated and redacted" do
    setup do
      start_http!(TransportCourt.CrashAgent)
    end

    test "a raising handler fails its task without leaking detail; a killed worker fails its task",
         %{url: url, agent: agent} do
      raise_msg = AshA2A.Protocol.JSON.encode!(AshA2A.Protocol.Message.new_user("raise"))
      resp = rpc(url, "message/send", %{"message" => raise_msg}, "tok-alice")
      body = Jason.decode!(resp.body)
      assert %{"result" => %{"task" => %{"status" => %{"state" => "TASK_STATE_FAILED"}}}} = body
      refute resp.body =~ "secret_column"
      assert resp.body =~ "internal_error"

      kill_msg = AshA2A.Protocol.JSON.encode!(AshA2A.Protocol.Message.new_user("kill"))
      body = rpc_json(url, "message/send", %{"message" => kill_msg}, "tok-alice")
      assert %{"result" => %{"task" => %{"status" => %{"state" => "TASK_STATE_FAILED"}}}} = body

      assert Process.alive?(agent)
    end
  end

  describe "SEC-03 execution leaves the agent mailbox free" do
    test "a slow action does not block other callers (async) but does in inline mode" do
      async = start_http!(TransportCourt.Agent)
      inline = start_http!(TransportCourt.InlineAgent)

      for {ctx, blocked?} <- [{async, false}, {inline, true}] do
        slow = Task.async(fn -> send_msg(ctx.url, "slow", %{"ms" => 1500}, "tok-alice") end)
        Process.sleep(200)
        {micros, body} = :timer.tc(fn -> send_msg(ctx.url, "whoami", %{}, "tok-bob") end)
        assert %{"subject" => "bob"} = artifact_data(body)
        assert %{"slept" => 1500} = artifact_data(Task.await(slow, 10_000))

        if blocked?,
          do: assert(micros > 1_000_000, "inline mode should serialize (#{micros}us)"),
          else: assert(micros < 1_000_000, "async mode blocked for #{micros}us")
      end
    end

    test "global in-flight cap refuses with -32000 server busy" do
      ctx = start_http!(TransportCourt.BusyAgent)
      slow = Task.async(fn -> send_msg(ctx.url, "slow", %{"ms" => 1000}, "tok-alice") end)
      Process.sleep(200)

      assert %{"error" => %{"code" => -32000, "data" => %{"reason" => "server_busy"}}} =
               send_msg(ctx.url, "whoami", %{}, "tok-bob")

      Task.await(slow, 10_000)
      assert %{"subject" => "bob"} = artifact_data(send_msg(ctx.url, "whoami", %{}, "tok-bob"))
    end

    test "per-principal token bucket refuses the principal over its rate, not others" do
      ctx = start_http!(TransportCourt.RateAgent)

      assert %{"subject" => "alice"} =
               artifact_data(send_msg(ctx.url, "whoami", %{}, "tok-alice"))

      assert %{"error" => %{"code" => -32000, "data" => %{"reason" => "rate_limited"}}} =
               send_msg(ctx.url, "whoami", %{}, "tok-alice")

      assert %{"subject" => "bob"} = artifact_data(send_msg(ctx.url, "whoami", %{}, "tok-bob"))
    end
  end

  describe "SEC-05 unauthenticated callers fail closed" do
    test "no verified identity is refused :unauthenticated unless the skill is public" do
      closed = start_http!(TransportCourt.Agent, auth?: false)
      body = send_msg(closed.url, "whoami", %{}, nil)

      assert %{
               "result" => %{
                 "task" => %{"status" => %{"state" => "TASK_STATE_FAILED", "message" => msg}}
               }
             } =
               body

      assert msg |> Map.fetch!("parts") |> hd() |> Map.fetch!("text") =~ ":unauthenticated"

      open = start_http!(TransportCourt.PublicAgent, auth?: false)
      assert %{"subject" => nil} = artifact_data(send_msg(open.url, "whoami", %{}, nil))

      body = send_msg(open.url, "ctx", %{}, nil)
      assert %{"result" => %{"task" => %{"status" => %{"state" => "TASK_STATE_FAILED"}}}} = body
    end
  end

  describe "SEC-11 client context is namespaced, never top-level" do
    setup do
      start_http!(TransportCourt.Agent)
    end

    test "metadata.context lands under :a2a_client_context only", %{url: url} do
      body = send_msg(url, "ctx", %{}, "tok-alice", %{"context" => %{"is_admin" => true}})
      assert %{"top_level_is_admin" => nil, "client_is_admin" => true} = artifact_data(body)
    end
  end

  describe "TQ-05 message/stream works for a non-streaming Ash skill" do
    setup do
      start_http!(TransportCourt.Agent)
    end

    test "answers text/event-stream with snapshot, artifact and final completed status", %{
      url: url
    } do
      resp = rpc(url, "message/stream", %{"message" => message("whoami", %{})}, "tok-alice")
      assert [ct | _] = Req.Response.get_header(resp, "content-type")
      assert ct =~ "text/event-stream"

      events =
        resp.body
        |> String.split("\n\n", trim: true)
        |> Enum.map(fn "data: " <> json -> json |> Jason.decode!() |> Map.fetch!("result") end)

      # v1.0 StreamResponse frames: the JSON-RPC result is discriminated by the
      # wrapper key -- {"task" => ...}, {"artifactUpdate" => ...},
      # {"statusUpdate" => ...} -- with no "kind" discriminator and no "final"
      # boolean anywhere on the wire (finality is the terminal status state).
      assert [%{"task" => %{"id" => _, "status" => _}} | _] = events
      assert Enum.any?(events, &match?(%{"artifactUpdate" => %{"artifact" => _}}, &1))

      assert %{"statusUpdate" => %{"status" => %{"state" => "TASK_STATE_COMPLETED"}}} =
               List.last(events)

      refute resp.body =~ ~s("kind")
      refute resp.body =~ ~s("final")

      refute resp.body =~ "SECRET"
    end
  end

  describe "CONF-06/CONF-09 truthful agent card" do
    test "capabilities advertise streaming and the SA2A extension at capabilities.extensions" do
      plain = start_http!(TransportCourt.Agent)
      card = Req.get!(plain.url <> "/.well-known/agent-card.json", retry: false).body
      assert %{"streaming" => true, "pushNotifications" => false} = card["capabilities"]
      refute Map.has_key?(card["capabilities"], "extensions")

      semantic =
        start_http!(TransportCourt.Agent,
          agent_card_opts: AshA2A.Semantic.Extension.advertise(url: "http://127.0.0.1/a2a")
        )

      card = Req.get!(semantic.url <> "/.well-known/agent-card.json", retry: false).body
      uri = AshA2A.Semantic.Extension.profile_uri()
      assert [%{"uri" => ^uri, "required" => false}] = card["capabilities"]["extensions"]

      assert Enum.any?(
               card["supportedInterfaces"],
               &(&1["protocolBinding"] == AshA2A.Semantic.Extension.profile_id())
             )
    end

    test "AgentCardBuilder struct capabilities agree with the wire" do
      card = AshA2A.Info.agent_card(TransportCourt.Probe)
      assert card.capabilities.streaming == true
      assert card.capabilities.push_notifications == false
    end
  end

  describe "SEC-08 wire-safe errors" do
    test "internal errors carry a ref, never the exception detail (by default)" do
      error =
        AshA2A.Transport.SafeError.internal(:internal_error, %RuntimeError{message: "pg secret"})

      assert %{code: :internal_error, ref: ref} = error
      assert is_binary(ref)
      refute Map.has_key?(error, :detail)
    end

    test "redact drops detail-bearing keys and non-atom tuple members" do
      assert AshA2A.Transport.SafeError.redact(%{code: :boom, detail: "SELECT 1"}) == %{
               code: :boom
             }

      assert AshA2A.Transport.SafeError.redact({:action_resolution, "pg: relation x"}) ==
               {:action_resolution, :redacted}
    end
  end

  describe "adversarial court: cancel, anonymous listing, redaction, issuers" do
    test "tasks/cancel on a running handler is refused; the task completes truthfully" do
      ctx = start_http!(TransportCourt.Agent)
      slow = Task.async(fn -> send_msg(ctx.url, "slow", %{"ms" => 1200}, "tok-alice") end)

      task_id =
        Enum.find_value(1..50, fn _ ->
          Process.sleep(20)

          case rpc_json(ctx.url, "tasks/list", %{}, "tok-alice") do
            %{"result" => %{"tasks" => [%{"id" => id} | _]}} -> id
            _ -> nil
          end
        end)

      assert is_binary(task_id)

      not_cancelable = task_not_cancelable_info()

      assert %{"error" => %{"code" => -32002, "data" => [^not_cancelable]}} =
               rpc_json(ctx.url, "tasks/cancel", %{"id" => task_id}, "tok-alice")

      done = Task.await(slow, 10_000)

      assert %{"result" => %{"task" => %{"status" => %{"state" => "TASK_STATE_COMPLETED"}}}} =
               done

      assert %{"slept" => 1200} = artifact_data(done)

      assert %{"result" => %{"status" => %{"state" => "TASK_STATE_COMPLETED"}}} =
               rpc_json(ctx.url, "tasks/get", %{"id" => task_id}, "tok-alice")
    end

    test "an anonymous caller cannot enumerate other anonymous callers' tasks" do
      ctx = start_http!(TransportCourt.CrashAgent, auth?: false)
      first = send_msg(ctx.url, "whoami", %{}, nil)
      assert %{"result" => %{"task" => %{"id" => task_id}}} = first

      assert %{"result" => %{"tasks" => []}} = rpc_json(ctx.url, "tasks/list", %{}, nil)

      # The unguessable id it was handed still addresses the task.
      assert %{"result" => %{"id" => ^task_id}} =
               rpc_json(ctx.url, "tasks/get", %{"id" => task_id}, nil)
    end

    test "command-bus refusal shapes never carry reason/receipt/nested structs onto the wire" do
      lost = %{
        code: :dispatch_lost,
        detail: "dispatch process died without replying; outcome unknown",
        reason: "{%RuntimeError{message: \"SELECT password FROM users\"}, []}"
      }

      assert AshA2A.Transport.SafeError.redact(lost) == %{code: :dispatch_lost}

      refused = %{code: :actuation_store_unavailable, receipt: %URI{userinfo: "u:secret"}}
      assert AshA2A.Transport.SafeError.redact(refused) == %{code: :actuation_store_unavailable}

      nested = %{code: :x, errors: [%{detail: "sql"}, {:y, "pg: z"}, self()]}

      assert AshA2A.Transport.SafeError.redact(nested) ==
               %{code: :x, errors: [%{}, {:y, :redacted}, :redacted]}
    end

    test "the same subject from two issuers is two principals" do
      a = AshA2A.Transport.Principal.key(%{sub: "alice", iss: "https://idp-a"})
      b = AshA2A.Transport.Principal.key(%{sub: "alice", iss: "https://idp-b"})
      refute a == b
    end
  end

  # ===========================================================================
  # TCK-driven transport pins (wrap-up of the Z19 TCK fixes over
  # `AshA2A.Transport.Plug`): the A2A-Version gate (TCK VER-SERVER-002),
  # `tasks/resubscribe` not-found (TCK STREAM-SUB-004), and agent-card
  # caching headers (TCK CARD-CACHE-001). Real HTTP through the real
  # `AshA2A.Transport.Plug`, real agent GenServers, zero mocks.
  # ===========================================================================
  describe "TCK-driven transport pins: version gate, resubscribe not-found, card caching headers" do
    @describetag :serial
    setup do
      start_http!(TransportCourt.Agent)
    end

    @tag :serial
    test "(VER-SERVER-002) A2A-Version 9.9 is refused -32009 VERSION_NOT_SUPPORTED",
         %{url: url} do
      resp =
        Req.post!(url,
          json: %{
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "message/send",
            "params" => %{"message" => message("whoami", %{})}
          },
          headers: [{"authorization", "Bearer tok-alice"}, {"a2a-version", "9.9"}],
          retry: false,
          receive_timeout: 15_000,
          decode_body: false
        )

      assert resp.status == 200

      assert %{
               "error" => %{
                 "code" => -32_009,
                 "message" => "Version not supported",
                 "data" => [
                   %{
                     "@type" => @error_info_type,
                     "domain" => @a2a_domain,
                     "reason" => "VERSION_NOT_SUPPORTED",
                     "metadata" => %{"detail" => "9.9"}
                   }
                 ]
               }
             } = Jason.decode!(resp.body)

      # Fixed (coordinator): the rejection path now echoes the rejected
      # version in the `a2a-version` response header too (spec §3.6.2).
      assert Req.Response.get_header(resp, "a2a-version") == ["9.9"]
    end

    @tag :serial
    test "(VER-SERVER-002) an absent A2A-Version header is tolerated at the default and echoes 0.3",
         %{url: url} do
      resp = rpc(url, "message/send", %{"message" => message("whoami", %{})}, "tok-alice")

      assert %{"result" => %{"task" => %{"id" => _, "status" => _}}} =
               Jason.decode!(resp.body)

      assert Enum.join(Req.Response.get_header(resp, "a2a-version"), "") == "0.3"
    end

    @tag :serial
    test "(STREAM-SUB-004) tasks/resubscribe: unknown task is -32001; an owned task on this plug is -32004",
         %{url: url} do
      unknown = task_not_found_info()

      assert %{"error" => %{"code" => -32_001, "data" => [^unknown]}} =
               rpc_json(url, "tasks/resubscribe", %{"id" => "tsk-unknown"}, "tok-alice")

      # An owned (input_required) task on this plug is addressable but has no
      # resubscribe stream to attach: UnsupportedOperationError (-32004).
      started = send_msg(url, "pair", %{"left" => "L"}, "tok-alice")
      assert %{"result" => %{"task" => %{"id" => task_id}}} = started

      unsupported = %{
        "@type" => @error_info_type,
        "domain" => @a2a_domain,
        "reason" => "UNSUPPORTED_OPERATION"
      }

      assert %{"error" => %{"code" => -32_004, "data" => [^unsupported]}} =
               rpc_json(url, "tasks/resubscribe", %{"id" => task_id}, "tok-alice")
    end

    @tag :serial
    test "(CARD-CACHE-001) the agent card serves Cache-Control max-age=60, ETag and Last-Modified",
         %{url: url} do
      resp = Req.get!(url <> "/.well-known/agent-card.json", retry: false)

      assert resp.status == 200
      assert Enum.join(Req.Response.get_header(resp, "cache-control"), "") == "max-age=60"

      assert [etag] = Req.Response.get_header(resp, "etag")
      assert String.starts_with?(etag, "\"") and String.ends_with?(etag, "\"")

      assert [_last_modified] = Req.Response.get_header(resp, "last-modified")
    end
  end

  # ===========================================================================
  # TCK-driven transport pins (lane G-F wrap-up of the Z19 TCK follow-up):
  # A2A v1.0 SendMessageResponse is a Task/Message oneof — a `{:message,
  # parts}` handler reply answers message/send with a bare Message (TCK
  # DM-MSG-001), and artifact parts carry the flat v1.0 part shapes (TCK
  # DM-ART-001). Real HTTP through the real `AshA2A.Transport.Plug`, real
  # agent GenServers, zero mocks.
  # ===========================================================================
  describe "TCK-driven transport pins: direct Message reply and typed artifact parts" do
    @describetag :serial
    setup do
      start_http!(TransportCourt.MessageAgent)
    end

    @tag :serial
    test "(DM-MSG-001) a `{:message, parts}` handler reply is a bare Message result, not a task",
         %{url: url} do
      assert %{
               "result" => %{
                 "message" => %{
                   "role" => "ROLE_AGENT",
                   "messageId" => message_id,
                   "parts" => [%{"text" => "Direct message response"}]
                 }
               }
             } = send_msg(url, "dm", %{}, "tok-alice")

      assert is_binary(message_id) and message_id != ""
      refute match?(%{"result" => %{"task" => _}}, send_msg(url, "dm", %{}, "tok-alice"))
    end

    @tag :serial
    test "(DM-ART-001) file artifact parts carry the flat v1.0 file shape (raw/filename/mediaType)",
         %{url: url} do
      assert %{
               "result" => %{
                 "task" => %{
                   "artifacts" => [
                     %{
                       "artifactId" => artifact_id,
                       "parts" => [
                         %{"raw" => raw, "filename" => "output.txt", "mediaType" => "text/plain"}
                       ]
                     }
                   ]
                 }
               }
             } = send_msg(url, "file-artifact", %{}, "tok-alice")

      assert is_binary(artifact_id) and artifact_id != ""
      assert is_binary(raw)
    end

    @tag :serial
    test "(DM-MSG-001) the direct-message task is finalized completed server-side, never stranded working",
         %{url: url} do
      # The transport runtime persists the turn's task before the handler
      # runs; after a `{:message, parts}` reply it must be terminal, and the
      # wire answer is still the bare Message.
      assert %{"result" => %{"message" => %{}}} = send_msg(url, "dm", %{}, "tok-alice")

      tasks =
        url
        |> rpc_json("tasks/list", %{}, "tok-alice")
        |> then(fn %{"result" => %{"tasks" => tasks}} -> tasks end)

      assert tasks != []

      assert Enum.all?(tasks, fn task ->
               task["status"]["state"] in ["TASK_STATE_COMPLETED", "TASK_STATE_INPUT_REQUIRED"]
             end)
    end
  end

  doctest AshA2A.Transport.Principal
  doctest AshA2A.Transport.SafeError

  describe "principal keys" do
    test "keyed by subject claim, stable across token refresh, never containing credentials" do
      a1 = AshA2A.Transport.Principal.key(%{sub: "alice", token: "t1", exp: 1})
      a2 = AshA2A.Transport.Principal.key(%{sub: "alice", token: "t2", exp: 2})
      assert a1 == a2
      refute a1 =~ "t1"
      assert "h:" <> _ = AshA2A.Transport.Principal.key(%{token: "only-a-token"})
      refute AshA2A.Transport.Principal.key(%{token: "only-a-token"}) =~ "only-a-token"
    end
  end
end
