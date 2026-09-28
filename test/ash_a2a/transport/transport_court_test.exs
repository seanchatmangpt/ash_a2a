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
  @impl A2A.Agent
  def handle_message(%A2A.Message{} = message, context) do
    case A2A.Message.text(message) do
      "raise" -> raise "SELECT secret_column FROM credentials -- internal detail"
      "kill" -> Process.exit(self(), :kill)
      _ -> super(message, context)
    end
  end
end

defmodule AshA2A.TransportCourt.Pipeline do
  @moduledoc false
  @behaviour Plug

  @schemes %{"bearer_auth" => %A2A.SecurityScheme.HTTPAuth{scheme: "bearer"}}

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    {auth?, opts} = Keyword.pop(opts, :auth?, true)

    conn =
      if auth?,
        do: A2A.Plug.Auth.call(conn, A2A.Plug.Auth.init(schemes: @schemes, verify: &verify/3)),
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
  CONF-06/09): real `AshA2A.Agent` GenServers, real `A2A.Plug.Auth` +
  `AshA2A.Transport.Plug` behind a real Bandit listener on an ephemeral
  port, real HTTP via Req. No mocks.
  """
  use ExUnit.Case, async: false

  alias AshA2A.TransportCourt

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
      A2A.Message.new_user([A2A.Part.Data.new(data)])
      | metadata: Map.put(extra_metadata, "skill", skill)
    }

    {:ok, json} = A2A.JSON.encode(msg)
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
      cont = %{A2A.Message.new_user([A2A.Part.Data.new(%{"right" => "R"})]) | task_id: task_id}
      {:ok, cont} = A2A.JSON.encode(%{cont | metadata: %{"skill" => "pair"}})
      b = rpc_json(url, "message/send", %{"message" => cont}, "tok-bob")
      assert %{"error" => %{"code" => -32001}} = b

      # B cannot read / cancel / list it.
      assert %{"error" => %{"code" => -32001}} =
               rpc_json(url, "tasks/get", %{"id" => task_id}, "tok-bob")

      assert %{"error" => %{"code" => -32001}} =
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
      message = %A2A.Message{
        role: :user,
        parts: [%A2A.Part.Data{data: "x"}],
        metadata: %{"skill" => "whoami"}
      }

      assert {:error, %{code: :invalid_input}} =
               AshA2A.Agent.__dispatch__(TransportCourt.Probe, message, %{}, [])
    end

    test "an exception inside dispatch becomes a typed internal_error with a ref" do
      message = %{A2A.Message.new_user("hi") | metadata: %{"skill" => "whoami"}}

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
      raise_msg = A2A.JSON.encode!(A2A.Message.new_user("raise"))
      resp = rpc(url, "message/send", %{"message" => raise_msg}, "tok-alice")
      body = Jason.decode!(resp.body)
      assert %{"result" => %{"task" => %{"status" => %{"state" => "TASK_STATE_FAILED"}}}} = body
      refute resp.body =~ "secret_column"
      assert resp.body =~ "internal_error"

      kill_msg = A2A.JSON.encode!(A2A.Message.new_user("kill"))
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

      assert [%{"kind" => "task"} | _] = events
      assert Enum.any?(events, &(&1["kind"] == "artifact-update"))

      assert %{"final" => true, "status" => %{"state" => "TASK_STATE_COMPLETED"}} =
               List.last(events)

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

      assert %{"error" => %{"code" => -32002}} =
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
