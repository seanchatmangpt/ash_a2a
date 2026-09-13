defmodule AshA2APlugAuthTest do
  @moduledoc """
  Real end-to-end auth test: a real `A2A.Plug.Auth` + real `A2A.Plug`
  pipeline, driven with `Plug.Test`, fronting a real `AshA2A.Agent`-generated
  agent. Sends a real HTTP POST with a real `Authorization: Bearer <token>`
  header through the real plug pipeline and asserts the verified identity
  actually threads into the real Ash action's `context.actor`/`context.tenant`
  -- proving the contract `AshA2A.Dispatcher`'s moduledoc documents actually
  holds through a real `A2A.Plug` transport, not just via a direct
  `dispatch/5` call that bypasses `A2A.Plug` entirely.

  Chicago-style throughout: real `Plug.Test.conn/3`, real
  `A2A.Plug.Auth.call/2`, real `A2A.Plug.call/2`, real supervised
  `A2A.Agent` GenServer, real JSON encode/decode via `A2A.JSON` and `Jason`.
  No Mock/mox/patch/monkeypatch anywhere in this file.
  """

  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias AshA2A.Test.Fixture.AuthProbeAgent

  @schemes %{"bearer_auth" => %A2A.SecurityScheme.HTTPAuth{scheme: "bearer"}}

  # Real verify callback: accepts exactly the token "valid-token-42" and maps
  # it to a real identity map carrying an id and a tenant claim -- exactly
  # the shape a resource author's own `:verify` function would return after
  # looking a token up in a real token store. Any other token is rejected.
  defp verify_callback("bearer_auth", "valid-token-42", _conn) do
    {:ok, %{id: "user-42", tenant: "acme"}}
  end

  defp verify_callback(_scheme, _credential, _conn), do: {:error, "invalid token"}

  setup do
    {:ok, _pid} = start_supervised({AuthProbeAgent, name: AuthProbeAgent})
    :ok
  end

  defp run_pipeline(conn) do
    auth_opts =
      A2A.Plug.Auth.init(
        schemes: @schemes,
        verify: &verify_callback/3
      )

    plug_opts =
      A2A.Plug.init(
        agent: AuthProbeAgent,
        base_url: "http://localhost:4000/a2a"
      )

    conn
    |> A2A.Plug.Auth.call(auth_opts)
    |> then(fn conn ->
      if conn.halted, do: conn, else: A2A.Plug.call(conn, plug_opts)
    end)
  end

  defp whoami_request_body do
    # `AuthProbe` now has 2 public actions (`:read` via `defaults([:read])`
    # plus the generic `:whoami`), so it exposes 2 real skills since fbc3213
    # "derive canonical skills from public Ash actions" -- explicit
    # `metadata["skill"]` is required to disambiguate (real regression,
    # confirmed via {:ambiguous_skill, ...} on a real failing run).
    message = %{A2A.Message.new_user([A2A.Part.Data.new(%{})]) | metadata: %{"skill" => "whoami"}}
    {:ok, message_json} = A2A.JSON.encode(message)

    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => "req-1",
      "method" => "message/send",
      "params" => %{"message" => message_json}
    })
  end

  test "a verified Bearer identity threads through A2A.Plug.Auth + A2A.Plug into the real Ash action's actor/tenant" do
    conn =
      :post
      |> conn("/", whoami_request_body())
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer valid-token-42")
      |> run_pipeline()

    refute conn.halted
    assert conn.status == 200

    body = Jason.decode!(conn.resp_body)
    assert %{"result" => %{"task" => task_json}} = body

    assert %{"status" => %{"state" => "TASK_STATE_COMPLETED"}, "artifacts" => [artifact]} =
             task_json

    assert %{"parts" => [%{"kind" => "data", "data" => data}]} = artifact

    # Real state reached by the real Ash action, via the real Plug.Auth ->
    # A2A.Plug -> AshA2A.Agent.__dispatch__ -> AshA2A.Dispatcher ->
    # AshA2A.ContextResolver chain -- not asserted via any mock/interaction.
    assert %{"actor" => %{"id" => "user-42", "tenant" => "acme"}, "tenant" => "acme"} = data
  end

  test "a missing Bearer credential is real-401-rejected by A2A.Plug.Auth before A2A.Plug ever runs" do
    conn =
      :post
      |> conn("/", whoami_request_body())
      |> put_req_header("content-type", "application/json")
      |> run_pipeline()

    assert conn.halted
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body) == %{"error" => "Unauthorized"}
  end

  test "an invalid Bearer token is real-rejected by the real verify callback" do
    conn =
      :post
      |> conn("/", whoami_request_body())
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer wrong-token")
      |> run_pipeline()

    assert conn.halted
    assert conn.status == 401
  end
end
