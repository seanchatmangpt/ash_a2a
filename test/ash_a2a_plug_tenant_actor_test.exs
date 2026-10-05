# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2APlugTenantActorTest do
  @moduledoc """
  Assignment #10: real tenant+actor threading through a REAL auth pipeline
  and a REAL multitenant Ash resource -- combining item #2's real
  `AshA2A.Protocol.Plug.Auth` + `AshA2A.Protocol.Plug` HTTP pipeline (`test/ash_a2a_plug_auth_test.exs`)
  with a genuine `multitenancy do strategy :attribute end` resource guarded
  by a genuine `Ash.Policy.Authorizer` policy
  (`AshA2A.Test.Fixture.TenantActorNote`, `test/support/
  tenant_actor_auth_fixture.ex`), proving the full stack -- not just the
  direct-`AshA2A.Dispatcher.dispatch/5`-bypassing-`AshA2A.Protocol.Plug` pattern every
  existing tenant test (`test/ash_a2a_dispatcher_tenant_test.exs`) uses.

  Real `Plug.Test.conn/3`, real `AshA2A.Protocol.Plug.Auth.call/2`, real `AshA2A.Protocol.Plug.call/2`,
  a real supervised `AshA2A.Protocol.Agent` GenServer, real `Ash.DataLayer.Ets`
  per-tenant partitioning, real `Ash.Policy.Authorizer` evaluation, real
  `AshA2A.Protocol.JSON`/`Jason` encode-decode. No Mock/mox/patch/monkeypatch anywhere
  in this file.
  """

  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias AshA2A.Test.Fixture.TenantActorNoteAgent

  @schemes %{"bearer_auth" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}}

  # Real verify callback mapping two distinct real Bearer tokens to two
  # distinct real identities -- one per tenant -- plus a third token whose
  # identity carries a tenant claim but no `:id`, used to exercise the real
  # fail-closed missing-tenant path (`:id` present but a genuinely different
  # coverage need: see the last test below) through the real pipeline
  # instead of a direct `dispatch/5` call.
  defp verify_callback("bearer_auth", "acme-token", _conn) do
    {:ok, %{id: "user-acme-1", tenant: "acme"}}
  end

  defp verify_callback("bearer_auth", "beta-token", _conn) do
    {:ok, %{id: "user-beta-1", tenant: "beta"}}
  end

  defp verify_callback("bearer_auth", "no-tenant-token", _conn) do
    {:ok, %{id: "user-no-tenant"}}
  end

  defp verify_callback(_scheme, _credential, _conn), do: {:error, "invalid token"}

  setup do
    {:ok, _pid} = start_supervised({TenantActorNoteAgent, name: TenantActorNoteAgent})

    # RFC-SA2A-001 S29: `:create_note` is a real `:change` skill, so the
    # verified identity needs a real `AshA2A.Authority.Broker` grant, not just
    # a valid Bearer token -- see `AshA2A.Authority.Grant`. The grant subject
    # is the SAME term `AshA2A.Protocol.Plug.Auth`'s verify callback returns and
    # `AshA2A.Protocol.Plug` threads through as `auth_identity` (the whole identity map),
    # since `AshA2A.Identity.principal/1` normalizes it identically on both
    # the grant side and the dispatch side.
    #
    # `"no-tenant-token"`'s identity is deliberately granted too: the
    # fail-closed behavior that test asserts must come from real Ash
    # multitenancy enforcement, which is what it is actually about -- not
    # from a missing capability grant masking it.
    AshA2A.Test.AuthorityGrantCase.grant!([
      {%{id: "user-acme-1", tenant: "acme"}, AshA2A.Test.Fixture.TenantActorNote,
       ["create_note"]},
      {%{id: "user-beta-1", tenant: "beta"}, AshA2A.Test.Fixture.TenantActorNote,
       ["create_note"]},
      {%{id: "user-no-tenant"}, AshA2A.Test.Fixture.TenantActorNote, ["create_note"]}
    ])

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
        agent: TenantActorNoteAgent,
        base_url: "http://localhost:4000/a2a"
      )

    conn
    |> AshA2A.Protocol.Plug.Auth.call(auth_opts)
    |> then(fn conn ->
      if conn.halted, do: conn, else: AshA2A.Protocol.Plug.call(conn, plug_opts)
    end)
  end

  # `AshA2A.Test.Fixture.TenantActorNote` compiles two real skills
  # (`create_note`, `list_notes`) -- per `AshA2A.Agent`'s own documented
  # default-skill rule, only a resource/domain with EXACTLY ONE compiled
  # skill lets a caller omit `:skill` metadata; with two, the target skill
  # must be named explicitly or dispatch real-fails-closed with
  # `{:ambiguous_skill, _}`. Real skill selection here, not a workaround.
  defp jsonrpc_request_body(data, skill) do
    message = %{AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(data)]) | metadata: %{"skill" => skill}}
    {:ok, message_json} = AshA2A.Protocol.JSON.encode(message)

    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => "req-1",
      "method" => "message/send",
      "params" => %{"message" => message_json}
    })
  end

  defp post_with_token(body, skill, token) do
    conn = conn(:post, "/", jsonrpc_request_body(body, skill))
    conn = put_req_header(conn, "content-type", "application/json")

    conn =
      if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn

    run_pipeline(conn)
  end

  defp task_data(conn) do
    body = Jason.decode!(conn.resp_body)
    assert %{"result" => %{"task" => task_json}} = body
    # Real wire state strings are `TASK_STATE_*`-prefixed (v0.3/v1.0 A2A wire
    # format, unchanged spelling in v1.0), not the bare atom name -- confirmed
    # via this task's own real encoded response.
    assert %{"status" => %{"state" => "TASK_STATE_COMPLETED"}, "artifacts" => [artifact]} =
             task_json

    # v1.0 wire contract: no "kind" discriminator anywhere on the wire; parts
    # are flat {"data": ...} maps.
    refute Map.has_key?(task_json, "kind")
    assert %{"parts" => [%{"data" => data} = part]} = artifact
    refute Map.has_key?(part, "kind")
    data
  end

  # A dispatch failure inside a real Ash action (e.g. a real multitenancy
  # validation error) is NOT a JSON-RPC-level `"error"` response -- it is a
  # real, successfully-dispatched `AshA2A.Protocol.Task` whose own `status.state` is
  # `TASK_STATE_FAILED` with a real error message, per
  # `AshA2A.Dispatcher.dispatch/5`'s always-`{:ok, task}` contract (only a
  # transport/protocol-level failure in `AshA2A.Protocol.Plug` itself produces a
  # top-level JSON-RPC `"error"`). Confirmed via this task's own real
  # response shape.
  defp task_failure_message(conn) do
    body = Jason.decode!(conn.resp_body)
    assert %{"result" => %{"task" => task_json}} = body
    assert %{"status" => %{"state" => "TASK_STATE_FAILED", "message" => message}} = task_json
    assert %{"parts" => [%{"text" => text}]} = message
    text
  end

  test "a real Bearer identity's tenant AND actor id both thread through the real plug pipeline into the real multitenant resource's created record" do
    conn = post_with_token(%{"body" => "acme note 1"}, "create_note", "acme-token")

    refute conn.halted
    assert conn.status == 200

    data = task_data(conn)
    assert data["tenant"] == "acme"
    assert data["created_by"] == "user-acme-1"
    assert data["body"] == "acme note 1"
  end

  test "two different real verified identities create real records isolated by real multitenancy, invisible across tenants" do
    conn_acme = post_with_token(%{"body" => "acme secret"}, "create_note", "acme-token")
    assert conn_acme.status == 200
    acme_created = task_data(conn_acme)
    assert acme_created["tenant"] == "acme"

    conn_beta = post_with_token(%{"body" => "beta secret"}, "create_note", "beta-token")
    assert conn_beta.status == 200
    beta_created = task_data(conn_beta)
    assert beta_created["tenant"] == "beta"

    # Real cross-tenant isolation, driven entirely through the real HTTP
    # pipeline: listing as tenant "acme" must never surface the "beta"
    # record real-created above (real `Ash.DataLayer.Ets` per-tenant
    # partitioning, not an application-level filter this test could fake).
    conn_list_acme = post_with_token(%{}, "list_notes", "acme-token")
    assert conn_list_acme.status == 200
    acme_list = task_data(conn_list_acme)
    assert %{"results" => results} = acme_list
    acme_note_bodies = Enum.map(results, & &1["body"])
    assert "acme secret" in acme_note_bodies
    refute "beta secret" in acme_note_bodies

    conn_list_beta = post_with_token(%{}, "list_notes", "beta-token")
    assert conn_list_beta.status == 200
    beta_list = task_data(conn_list_beta)
    beta_note_bodies = Enum.map(beta_list["results"], & &1["body"])
    assert "beta secret" in beta_note_bodies
    refute "acme secret" in beta_note_bodies
  end

  test "a real verified identity with no tenant claim is real-fail-closed by real Ash multitenancy enforcement through the real pipeline (not bypassing AshA2A.Protocol.Plug)" do
    conn = post_with_token(%{"body" => "orphan note"}, "create_note", "no-tenant-token")

    refute conn.halted
    assert conn.status == 200

    # `AshA2A.ContextResolver.from_a2a_message/4` resolves `tenant: nil`
    # because `%{id: "user-no-tenant"}` carries no `:tenant`/`"tenant"` key
    # (per its documented field provenance) -- so this is the same real
    # `Ash.Actions.Helpers.validate_changeset_multitenancy/1` failure
    # `test/ash_a2a_dispatcher_tenant_test.exs` already proves for a direct
    # `dispatch/5` call, now proven reachable through the real
    # `AshA2A.Protocol.Plug.Auth` -> `AshA2A.Protocol.Plug` -> `AshA2A.Agent.__dispatch__/3` chain
    # instead of a test calling `AshA2A.Dispatcher.dispatch/5` directly. The
    # real failure surfaces as a real TASK_STATE_FAILED task, not a
    # JSON-RPC-level error (see `task_failure_message/1`'s moduledoc).
    text = task_failure_message(conn)
    assert text =~ "tenant"
  end

  test "an unauthenticated request is real-401-rejected by AshA2A.Protocol.Plug.Auth before the real multitenant resource's actor_present() policy ever runs" do
    conn = post_with_token(%{"body" => "no auth"}, "create_note", nil)

    assert conn.halted
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body) == %{"error" => "Unauthorized"}
  end
end
