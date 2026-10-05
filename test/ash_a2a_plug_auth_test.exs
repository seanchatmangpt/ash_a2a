# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2APlugAuthTest do
  @moduledoc """
  Real end-to-end auth test: a real `AshA2A.Protocol.Plug.Auth` + real `AshA2A.Protocol.Plug`
  pipeline, driven with `Plug.Test`, fronting a real `AshA2A.Agent`-generated
  agent. Sends a real HTTP POST with a real `Authorization: Bearer <token>`
  header through the real plug pipeline and asserts the verified identity
  actually threads into the real Ash action's `context.actor`/`context.tenant`
  -- proving the contract `AshA2A.Dispatcher`'s moduledoc documents actually
  holds through a real `AshA2A.Protocol.Plug` transport, not just via a direct
  `dispatch/5` call that bypasses `AshA2A.Protocol.Plug` entirely.

  Chicago-style throughout: real `Plug.Test.conn/3`, real
  `AshA2A.Protocol.Plug.Auth.call/2`, real `AshA2A.Protocol.Plug.call/2`, real supervised
  `AshA2A.Protocol.Agent` GenServer, real JSON encode/decode via `AshA2A.Protocol.JSON` and `Jason`.
  No Mock/mox/patch/monkeypatch anywhere in this file.
  """

  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias AshA2A.Test.Fixture.AuthProbeAgent

  @schemes %{"bearer_auth" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}}

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
      AshA2A.Protocol.Plug.Auth.init(
        schemes: @schemes,
        verify: &verify_callback/3
      )

    plug_opts =
      AshA2A.Protocol.Plug.init(
        agent: AuthProbeAgent,
        base_url: "http://localhost:4000/a2a"
      )

    conn
    |> AshA2A.Protocol.Plug.Auth.call(auth_opts)
    |> then(fn conn ->
      if conn.halted, do: conn, else: AshA2A.Protocol.Plug.call(conn, plug_opts)
    end)
  end

  defp whoami_request_body do
    # `AuthProbe` now has 2 public actions (`:read` via `defaults([:read])`
    # plus the generic `:whoami`), so it exposes 2 real skills since fbc3213
    # "derive canonical skills from public Ash actions" -- explicit
    # `metadata["skill"]` is required to disambiguate (real regression,
    # confirmed via {:ambiguous_skill, ...} on a real failing run).
    message = %{AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(%{})]) | metadata: %{"skill" => "whoami"}}
    {:ok, message_json} = AshA2A.Protocol.JSON.encode(message)

    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => "req-1",
      "method" => "message/send",
      "params" => %{"message" => message_json}
    })
  end

  test "a verified Bearer identity threads through AshA2A.Protocol.Plug.Auth + AshA2A.Protocol.Plug into the real Ash action's actor/tenant" do
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

    # v1.0 wire contract: no "kind" discriminator anywhere on the wire.
    refute Map.has_key?(task_json, "kind")

    assert %{"status" => %{"state" => "TASK_STATE_COMPLETED"}, "artifacts" => [artifact]} =
             task_json

    # Parts are flat v1.0 wire maps: {"data": ...} with no "kind" key.
    assert %{"parts" => [%{"data" => data} = part]} = artifact
    refute Map.has_key?(part, "kind")

    # Real state reached by the real Ash action, via the real Plug.Auth ->
    # AshA2A.Protocol.Plug -> AshA2A.Agent.__dispatch__ -> AshA2A.Dispatcher ->
    # AshA2A.ContextResolver chain -- not asserted via any mock/interaction.
    assert %{"actor" => %{"id" => "user-42", "tenant" => "acme"}, "tenant" => "acme"} = data
  end

  test "a missing Bearer credential is real-401-rejected by AshA2A.Protocol.Plug.Auth before AshA2A.Protocol.Plug ever runs" do
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
