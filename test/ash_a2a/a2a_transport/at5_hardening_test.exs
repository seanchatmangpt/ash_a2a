# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.A2ATransport.At5HardeningTest.ReplyAgent do
  @moduledoc false
  use AshA2A.Protocol.Agent, name: "at5-reply", description: "replies ok"

  @impl true
  def handle_message(_message, _context), do: {:reply, [AshA2A.Protocol.Part.Text.new("ok")]}
end

defmodule AshA2A.A2ATransport.At5HardeningTest.CrashAgent do
  @moduledoc false
  # Real agent whose handler genuinely crashes — the crash surfaces on the
  # wire only through the transport's error shaping, never verbatim.
  use AshA2A.Protocol.Agent, name: "at5-crash", description: "crashes"

  @impl true
  def handle_message(_message, _context),
    do: raise(RuntimeError, "pg secret connection refused 10.0.0.9")
end

defmodule AshA2A.A2ATransport.At5HardeningTest do
  @moduledoc """
  Adversarial hardening court for lane AT5 over the real HTTP surface:

    1. `params.metadata` cannot clobber the verified `"a2a.auth"` identity
       (auth downgrade / authorizer spoofing via the JSON-RPC metadata merge).
    2. Handler crashes answer -32603 with an opaque `ref` — the exception
       text never reaches the wire (SEC-08).
    3. The push sender refuses non-HTTP(S) webhook URLs and credential
       values carrying control characters (header injection) typed, before
       any connection is opened.
  """

  use ExUnit.Case, async: true

  alias AshA2A.A2ATransport.At5HardeningTest.{CrashAgent, ReplyAgent}
  alias AshA2A.Protocol.Plug, as: VendoredPlug
  alias AshA2A.Protocol.PushNotificationSender.HTTP, as: PushHTTP

  @schemes %{"bearer" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}}

  def verify("bearer", token, _conn), do: {:ok, %{sub: token}}

  setup do
    uniq = System.unique_integer([:positive])
    reply_agent = :"at5_reply_#{uniq}"
    crash_agent = :"at5_crash_#{uniq}"
    start_supervised!({ReplyAgent, name: reply_agent})
    start_supervised!({CrashAgent, name: crash_agent})

    %{
      reply_agent: reply_agent,
      crash_agent: crash_agent,
      auth: AshA2A.Protocol.Plug.Auth.init(schemes: @schemes, verify: &__MODULE__.verify/3)
    }
  end



  defp rpc(ctx, user, agent, method, params) do
    body =
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => 7, "method" => method, "params" => params})

    conn =
      Plug.Test.conn(:post, "/", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> user)
      |> AshA2A.Protocol.Plug.Auth.call(ctx.auth)
      |> VendoredPlug.call(
        VendoredPlug.init(
          agent: agent,
          base_url: "http://x/a2a",
          authorize_task: &__MODULE__.authorizer/3
        )
      )

    conn.resp_body |> Jason.decode!()
  end

  # Real authorizer that trusts the verified identity off the metadata the
  # transport assembled — exactly what an operator callback does.
  def authorizer(_op, _task, context) do
    case context.metadata do
      %{"a2a.auth" => %{identity: %{sub: "alice"}}} -> :ok
      _ -> {:error, :denied}
    end
  end

  defp message do
    {:ok, encoded} = AshA2A.Protocol.JSON.encode(AshA2A.Protocol.Message.new_user("go"))
    encoded
  end

  # -- (1) verified auth cannot be clobbered via params.metadata -------------

  test "params.metadata cannot forge or strip the verified a2a.auth identity", ctx do
    # A task exists, so tasks/get reaches the real authorizer.
    assert %{"result" => %{"task" => %{"id" => task_id}}} =
             rpc(ctx, "alice", ctx.reply_agent, "message/send", %{"message" => message()})

    forged = %{
      "metadata" => %{"a2a.auth" => "attacker-chosen", "legit" => "still-accepted"}
    }

    # The verified bearer IS alice; her authorizer admits her. Before the fix
    # the forged params.metadata replaced the verified a2a.auth and even the
    # genuine owner was denied (auth downgrade); after the fix the verified
    # identity survives the merge and the task is returned.
    assert %{"result" => %{"id" => ^task_id}} =
             rpc(ctx, "alice", ctx.reply_agent, "tasks/get", Map.put(forged, "id", task_id))

    # A foreign session carrying the same forged metadata is still denied —
    # the dropped key cannot be used to impersonate either.
    assert %{"error" => %{"code" => -32_001}} =
             rpc(ctx, "mallory", ctx.reply_agent, "tasks/get", Map.put(forged, "id", task_id))
  end

  # -- (2) handler crashes are ref-only on the wire ---------------------------

  test "a crashing handler answers -32603 with an opaque ref, no exception text", ctx do
    body = rpc(ctx, "alice", ctx.crash_agent, "message/send", %{"message" => message()})
    raw = Jason.encode!(body)

    assert %{"error" => %{"code" => -32_603, "data" => %{"ref" => ref, "code" => "internal_error"}}} =
             body

    assert is_binary(ref) and ref != ""
    refute raw =~ "pg secret"
    refute raw =~ "10.0.0.9"
  end

  # -- (3) push sender URL-scheme and credential hygiene ----------------------

  describe "push sender hardening" do
    test "non-http(s) webhook URLs are refused typed" do
      config = %AshA2A.Protocol.PushNotificationConfig{url: "file:///etc/passwd"}

      assert {:error, {:unsupported_scheme, "file"}} =
               PushHTTP.deliver(config, %{"taskId" => "t1"})
    end

    test "credentials carrying control characters are refused before dialing" do
      config = %AshA2A.Protocol.PushNotificationConfig{
        url: "http://example.invalid/hook",
        authentication: %{scheme: "Bearer", credentials: "tok\r\nX-Injected: 1"}
      }

      assert {:error, {:invalid_credentials, :control_characters}} =
               PushHTTP.deliver(config, %{"taskId" => "t1"})
    end

    test "bearer token carrying CRLF is refused before dialing" do
      config = %AshA2A.Protocol.PushNotificationConfig{
        url: "http://example.invalid/hook",
        token: "tok\nX-Injected: 1"
      }

      assert {:error, {:invalid_credentials, :control_characters}} =
               PushHTTP.deliver(config, %{"taskId" => "t1"})
    end
  end
end
