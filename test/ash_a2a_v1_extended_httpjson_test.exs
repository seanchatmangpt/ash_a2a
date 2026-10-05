# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.V1ExtendedHTTPJSONTest.Pipeline do
  @moduledoc """
  Real composite plug used by `AshA2A.V1ExtendedHTTPJSONTest`: a real
  `AshA2A.Protocol.Plug.Auth` (Bearer) in front of the real
  `AshA2A.A2ATransport.Plug` carrying an `:extended_card` provider. Mounted on
  a real Bandit listener, this is the exact stack an operator deploys for the
  authenticated extended card (`agent/getAuthenticatedExtendedCard`).
  """

  @behaviour Plug

  @doc false
  # Idempotent: Bandit re-invokes `init/1` on the already-pinned map.
  def init(opts) when is_map(opts), do: opts

  def init(opts) do
    transport =
      AshA2A.A2ATransport.Plug.init(
        agent: Keyword.fetch!(opts, :agent),
        base_url: "http://127.0.0.1/a2a",
        extended_card: Keyword.get(opts, :extended_card)
      )

    auth =
      if opts[:auth] == false do
        nil
      else
        AshA2A.Protocol.Plug.Auth.init(
          schemes: %{"bearer_auth" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}},
          verify: Keyword.fetch!(opts, :verify)
        )
      end

    %{auth: auth, transport: transport}
  end

  @impl Plug
  def call(conn, %{auth: nil, transport: transport}), do: AshA2A.A2ATransport.Plug.call(conn, transport)

  def call(conn, %{auth: auth, transport: transport}) do
    conn
    |> AshA2A.Protocol.Plug.Auth.call(auth)
    |> then(fn conn ->
      if conn.halted, do: conn, else: AshA2A.A2ATransport.Plug.call(conn, transport)
    end)
  end
end

defmodule AshA2A.V1ExtendedHTTPJSONTest.RestPipeline do
  @moduledoc """
  Real composite plug for the REST surface under test: a real
  `AshA2A.Protocol.Plug.Auth` (Bearer) in front of the real
  `AshA2A.Transport.HTTPJSON` binding carrying an `:extended_card` provider --
  the exact stack an operator deploys for the authenticated extended card over
  the v1.0 REST binding.
  """

  @behaviour Plug

  @doc false
  def init(opts) when is_map(opts), do: opts

  def init(opts) do
    rest =
      AshA2A.Transport.HTTPJSON.init(
        agent: Keyword.fetch!(opts, :agent),
        base_url: "http://127.0.0.1/a2a",
        extended_card: Keyword.get(opts, :extended_card)
      )

    auth =
      if opts[:auth] == false do
        nil
      else
        AshA2A.Protocol.Plug.Auth.init(
          schemes: %{"bearer_auth" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}},
          verify: Keyword.fetch!(opts, :verify)
        )
      end

    %{auth: auth, rest: rest}
  end

  @impl Plug
  def call(conn, %{auth: nil, rest: rest}), do: AshA2A.Transport.HTTPJSON.call(conn, rest)

  def call(conn, %{auth: auth, rest: rest}) do
    conn
    |> AshA2A.Protocol.Plug.Auth.call(auth)
    |> then(fn conn ->
      if conn.halted, do: conn, else: AshA2A.Transport.HTTPJSON.call(conn, rest)
    end)
  end
end

defmodule AshA2A.V1ExtendedHTTPJSONTest do
  @moduledoc """
  Court pinning the authenticated extended-card flows
  (`agent/getAuthenticatedExtendedCard`, JSON-RPC method; `POST /agent`, REST
  binding) on the two real HTTP surfaces of this repo, over real Bandit HTTP
  and a real `AshA2A.Agent` GenServer. No mocks.

  ## The REST binding serves `POST /agent` (gap closed)

  `AshA2A.Transport.HTTPJSON` implements the authenticated extended-card REST
  route `POST /agent`: the same provider flow as the JSONRPC wrapper
  (`AshA2A.A2ATransport.ExtendedCard`'s provider contract) with the REST
  envelope. Pinned positively: a verified caller gets the provider-extended
  card itself (per call, for that call's identity); an unauthenticated caller
  is `401` with a `Bearer` challenge and a `-32600` envelope, whether the auth
  plug halted or the binding saw no identity; no provider and provider error
  fail closed to the `-32007` `ErrorInfo` envelope -- the public card is never
  substituted. One plain-404 control remains for a genuinely unknown path
  (`POST /agent:getAuthenticatedExtendedCard` is not an implemented route).

  ## The real extended-card flow runs over the JSONRPC wrapper

  `AshA2A.A2ATransport.Plug` + `AshA2A.A2ATransport.ExtendedCard` + a real
  `:extended_card` provider, front-mounted with a real
  `AshA2A.Protocol.Plug.Auth`: unauthenticated callers are 401-challenged by
  the auth plug (or by the transport plug itself when mounted without one);
  authenticated callers get the provider-extended card per call; the
  provider's output card is stripped of the internal credential keys
  (`"a2a.auth"`, the owner key, the raw stream ref) before serving, like task
  payloads; provider error/crash and no-provider fail closed to -32007 and
  never substitute the public card.
  """

  use ExUnit.Case, async: false

  @moduletag :serial_shard

  alias AshA2A.Test.EphemeralHttp
  alias AshA2A.Test.PlugFixture.GreeterAgent
  alias AshA2A.Transport.HTTPJSON, as: RestBinding

  @error_info "type.googleapis.com/google.rpc.ErrorInfo"
  @ext_not_configured "EXTENDED_AGENT_CARD_NOT_CONFIGURED"

  setup do
    name = :"ext_httpjson_agent_#{System.unique_integer([:positive])}"
    {:ok, pid} = GreeterAgent.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    # Real per-test invocation counter a real Agent process bumps -- per-call
    # provider invocation is asserted on real counted state, never on mocks.
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    %{agent: name, counter: counter}
  end

  # -- providers (real public 2-arity functions, the provider contract) --------

  def admin_card_provider(%{identity: %{sub: sub}}, card) do
    skill = %{"id" => "admin", "name" => "Admin", "description" => "for #{sub}", "tags" => []}
    {:ok, Map.update!(card, "skills", &(&1 ++ [skill]))}
  end

  def counting_admin_provider(counter, %{identity: %{sub: sub}}, card) do
    Agent.update(counter, &(&1 + 1))

    skill = %{"id" => "admin", "name" => "Admin", "description" => "for #{sub}", "tags" => []}
    {:ok, Map.update!(card, "skills", &(&1 ++ [skill]))}
  end

  def failing_provider(_identity, _card), do: {:error, :denied}
  def crashing_provider(_identity, _card), do: raise("boom")

  # A provider that smuggles credential-shaped keys into its output: the court
  # observes what actually reaches the wire.
  def credential_smuggling_provider(_identity, card) do
    leaky_skill = %{
      "id" => "leak",
      "name" => "Leak",
      "description" => "nested credential attempt",
      "tags" => [],
      "metadata" => %{"a2a.auth" => "nested-credential"}
    }

    {:ok,
     card
     |> Map.merge(%{
       "metadata" => %{"a2a.auth" => "raw-credential", "ash_a2a.owner" => "alice"},
       "secret" => "s3cr3t"
     })
     |> Map.update("skills", [leaky_skill], &[leaky_skill | &1])}
  end

  # Never executed: the {m, f, a} provider below is not a CallbackRegistry
  # member, so `AshA2A.CallbackRegistry.invoke/3` must refuse without calling.
  def forbidden_mfa_provider(_identity, _card) do
    :persistent_term.put({__MODULE__, :forbidden_mfa_ran}, true)
    {:ok, %{}}
  end

  # -- fixtures ------------------------------------------------------------------

  defp verify(_scheme, "valid-token-42", _conn), do: {:ok, %{sub: "alice"}}
  defp verify(_scheme, "valid-token-77", _conn), do: {:ok, %{sub: "bob"}}
  defp verify(_scheme, _credential, _conn), do: {:error, "invalid token"}

  defp start_auth_server!(agent, provider, verify_fun \\ &verify/3) do
    opts =
      AshA2A.V1ExtendedHTTPJSONTest.Pipeline.init(
        agent: agent,
        extended_card: provider,
        verify: verify_fun
      )

    EphemeralHttp.start!({AshA2A.V1ExtendedHTTPJSONTest.Pipeline, opts})
  end

  defp start_transport_only_server!(agent, provider) do
    # Raw keyword opts: `AshA2A.A2ATransport.Plug.init/1` is not idempotent on
    # its pinned map, and Bandit calls `init/1` itself on {plug, opts}.
    EphemeralHttp.start!(
      {AshA2A.A2ATransport.Plug, [agent: agent, base_url: "http://127.0.0.1/a2a", extended_card: provider]}
    )
  end

  defp start_rest_server!(agent) do
    EphemeralHttp.start!({RestBinding, RestBinding.init(agent: agent, base_url: "http://127.0.0.1/fixture")})
  end

  # REST server with a real auth plug in front of the REST binding.
  defp start_authenticated_rest_server!(agent, provider) do
    opts =
      AshA2A.V1ExtendedHTTPJSONTest.RestPipeline.init(
        agent: agent,
        extended_card: provider,
        verify: &verify/3
      )

    EphemeralHttp.start!({AshA2A.V1ExtendedHTTPJSONTest.RestPipeline, opts})
  end

  # REST binding mounted WITHOUT an auth plug: the binding itself must fail
  # closed on the missing verified identity.
  defp start_bare_rest_server!(agent, provider) do
    EphemeralHttp.start!(
      {RestBinding,
       RestBinding.init(agent: agent, base_url: "http://127.0.0.1/a2a", extended_card: provider)}
    )
  end

  defp rpc!(server, method, token \\ nil, id \\ 7) do
    body =
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => %{}})

    headers = [{"content-type", "application/json"}]
    headers = if token, do: [{"authorization", "Bearer " <> token} | headers], else: headers

    Req.post!(url: server.base_url <> "/", headers: headers, body: body)
  end

  defp post_agent!(server, token \\ nil) do
    headers = if token, do: [{"authorization", "Bearer " <> token}], else: []
    Req.post!(url: server.base_url <> "/agent", headers: headers, json: %{}, decode_body: false)
  end

  defp public_card_skills(server) do
    server.base_url <> "/.well-known/agent-card.json" |> Req.get!() |> Map.fetch!(:body) |> Map.fetch!("skills")
  end

  # =============================================================================
  # PART 1 -- the REST binding (`AshA2A.Transport.HTTPJSON`) serves the
  # authenticated extended card at `POST /agent` (gap closed).
  # =============================================================================

  @tag :serial_shard
  test "REST binding: an authenticated caller receives the provider-extended card for that call's identity", %{
    agent: agent
  } do
    server = start_authenticated_rest_server!(agent, &admin_card_provider/2)

    resp = post_agent!(server, "valid-token-42")
    assert resp.status == 200, "status=#{resp.status} body=#{resp.body}"

    card = Jason.decode!(resp.body)

    # Success is the extended card itself (the REST binding has no JSON-RPC
    # oneof wrapper), carrying the provider's per-identity skill...
    ids = Enum.map(card["skills"], & &1["id"])
    assert "admin" in ids
    assert Enum.find(card["skills"], &(&1["id"] == "admin"))["description"] == "for alice"

    # ...and a second call with a different verified identity gets ITS
    # identity's extension.
    resp2 = post_agent!(server, "valid-token-77")
    assert resp2.status == 200
    card2 = Jason.decode!(resp2.body)
    assert Enum.find(card2["skills"], &(&1["id"] == "admin"))["description"] == "for bob"

    # The public card, fetched unauthenticated from the same server, never
    # carries the admin skill: the extension exists only per-call.
    refute "admin" in Enum.map(public_card_skills(server), & &1["id"])
  end

  @tag :serial_shard
  test "REST binding: POST /agent without an auth plug still fails closed -- 401, Bearer challenge, -32600 envelope, never the public card", %{
    agent: agent
  } do
    server = start_bare_rest_server!(agent, &admin_card_provider/2)

    resp = post_agent!(server)

    assert resp.status == 401
    assert resp.headers["www-authenticate"] == ["Bearer"]

    assert %{
             "error" => %{
               "code" => 401,
               "message" => "Request payload validation error",
               "details" => "authentication required"
             }
           } = Jason.decode!(resp.body)

    # Never the public card.
    refute Jason.decode!(resp.body) |> Map.has_key?("skills")
  end

  @tag :serial_shard
  test "REST binding: no :extended_card provider answers the -32007 ErrorInfo envelope even for a verified caller, never the public card", %{
    agent: agent
  } do
    server = start_authenticated_rest_server!(agent, nil)

    resp = post_agent!(server, "valid-token-42")

    assert resp.status == 400

    assert %{
             "error" => %{
               "code" => 400,
               "message" => "Authenticated Extended Card is not configured",
               "details" => [
                 %{
                   "@type" => @error_info,
                   "domain" => "a2a-protocol.org",
                   "reason" => @ext_not_configured
                 }
               ]
             }
           } = Jason.decode!(resp.body)

    refute Jason.decode!(resp.body) |> Map.has_key?("skills")
  end

  @tag :serial_shard
  test "REST binding: a failing provider answers -32007 with the reason, never the public card", %{
    agent: agent
  } do
    server = start_authenticated_rest_server!(agent, &failing_provider/2)

    resp = post_agent!(server, "valid-token-42")

    assert resp.status == 400

    assert %{
             "error" => %{
               "code" => 400,
               "details" => [
                 %{"@type" => @error_info, "reason" => @ext_not_configured, "metadata" => %{"detail" => detail}}
               ]
             }
           } = Jason.decode!(resp.body)

    assert detail =~ ":denied"
    refute Jason.decode!(resp.body) |> Map.has_key?("skills")
  end

  @tag :serial_shard
  test "REST binding: a crashing provider answers -32007, never the public card", %{agent: agent} do
    server = start_authenticated_rest_server!(agent, &crashing_provider/2)

    resp = post_agent!(server, "valid-token-42")

    assert resp.status == 400

    assert %{
             "error" => %{
               "code" => 400,
               "details" => [%{"metadata" => %{"detail" => detail}}]
             }
           } = Jason.decode!(resp.body)

    assert detail =~ "provider_raised"
    assert detail =~ "boom"
    refute Jason.decode!(resp.body) |> Map.has_key?("skills")
  end

  test "REST binding: the well-known card serves the extendedAgentCard capability as literal false", %{
    agent: agent
  } do
    server = start_rest_server!(agent)

    card = Req.get!(url: server.base_url <> "/.well-known/agent-card.json").body

    # Pinned as-served: the REST binding's card encode path pins every
    # capability key, so `extendedAgentCard` appears as literal `false` (the
    # REST binding's well-known advertisement does not follow the per-call
    # provider -- the true-advertising surface is the JSONRPC wrapper's plug).
    assert %{"capabilities" => %{"extendedAgentCard" => false}} = card
  end

  # The CallbackRegistry closure holds on the REST surface too: a {m, f, a}
  # provider outside the registry is refused -32007 (the same envelope the
  # JSONRPC binding answers) and the callback is never executed.
  test "REST binding: a {m, f, a} provider outside CallbackRegistry is -32007 and the callback is never executed", %{
    agent: agent
  } do
    :persistent_term.erase({__MODULE__, :forbidden_mfa_ran})

    server = start_authenticated_rest_server!(agent, {__MODULE__, :forbidden_mfa_provider, []})

    resp = post_agent!(server, "valid-token-42")

    assert resp.status == 400

    assert %{
             "error" => %{
               "code" => 400,
               "details" => [%{"metadata" => %{"detail" => detail}}]
             }
           } = Jason.decode!(resp.body)

    assert detail =~ "callback_not_permitted"
    refute :persistent_term.get({__MODULE__, :forbidden_mfa_ran}, false)
  end

  # 404 control: a genuinely unknown path is still the plain catch-all 404.
  test "REST binding: POST /agent:getAuthenticatedExtendedCard is a plain 404 fallthrough (not an implemented route)", %{
    agent: agent
  } do
    server = start_rest_server!(agent)

    resp =
      Req.post!(url: server.base_url <> "/agent:getAuthenticatedExtendedCard",
        json: %{},
        decode_body: false
      )

    assert resp.status == 404
    assert resp.body == "Not Found"
  end

  # =============================================================================
  # PART 2 -- the real extended-card flow over the JSONRPC wrapper
  # (real Auth plug -> A2ATransport.Plug -> ExtendedCard -> provider).
  # =============================================================================

  # (a) unauthenticated caller
  test "(a) unauthenticated RPC through the real auth plug is 401 with a Bearer challenge", %{agent: agent} do
    server = start_auth_server!(agent, {__MODULE__, :admin_card_provider, []})

    resp = rpc!(server, "agent/getAuthenticatedExtendedCard")

    assert resp.status == 401
    assert resp.headers["www-authenticate"] == [~s(Bearer realm="a2a")]
    assert resp.body == %{"error" => "Unauthorized"}
  end

  test "(a) transport plug mounted WITHOUT an auth plug still fails closed: 401 + -32600 + WWW-Authenticate", %{
    agent: agent
  } do
    server = start_transport_only_server!(agent, &admin_card_provider/2)

    resp = rpc!(server, "agent/getAuthenticatedExtendedCard")

    assert resp.status == 401
    assert resp.headers["www-authenticate"] == ["Bearer"]

    assert %{"jsonrpc" => "2.0", "id" => 7, "error" => %{"code" => -32_600, "data" => "authentication required"}} =
             resp.body
  end

  # (b) authenticated caller -> provider-extended card, per call
  test "(b) authenticated caller receives the provider-extended card; provider invoked per call with that call's identity", %{
    agent: agent,
    counter: counter
  } do
    server = start_auth_server!(agent, fn id, card -> counting_admin_provider(counter, id, card) end)

    resp = rpc!(server, "agent/getAuthenticatedExtendedCard", "valid-token-42")
    assert resp.status == 200

    assert %{"jsonrpc" => "2.0", "id" => 7, "result" => card} = resp.body
    refute Map.has_key?(resp.body, "error")

    ids = Enum.map(card["skills"], & &1["id"])
    assert "admin" in ids
    assert Enum.find(card["skills"], &(&1["id"] == "admin"))["description"] == "for alice"

    # Per-call: a different verified identity on a second call gets ITS
    # identity's extension, and the real counter shows two provider runs.
    resp2 = rpc!(server, "agent/getAuthenticatedExtendedCard", "valid-token-77", 8)
    assert %{"id" => 8, "result" => card2} = resp2.body
    assert Enum.find(card2["skills"], &(&1["id"] == "admin"))["description"] == "for bob"
    assert Agent.get(counter, & &1) == 2

    # The public card, fetched unauthenticated from the same server, never
    # carries the admin skill: the extension exists only per-call.
    refute "admin" in Enum.map(public_card_skills(server), & &1["id"])
  end

  test "(b) the PascalCase v1.0 alias GetExtendedAgentCard routes identically", %{agent: agent} do
    server = start_auth_server!(agent, &admin_card_provider/2)

    resp = rpc!(server, "GetExtendedAgentCard", "valid-token-42")

    assert resp.status == 200
    assert %{"result" => %{"skills" => skills}} = resp.body
    assert "admin" in Enum.map(skills, & &1["id"])
  end

  # (c) provider error / crash -> -32007, never the public card
  test "(c) a provider error answers -32007 and never the public card", %{agent: agent} do
    server = start_auth_server!(agent, &failing_provider/2)

    resp = rpc!(server, "agent/getAuthenticatedExtendedCard", "valid-token-42")

    assert resp.status == 200

    assert %{"error" => %{
               "code" => -32_007,
               "message" => "Authenticated Extended Card is not configured",
               "data" => [%{"@type" => @error_info, "reason" => @ext_not_configured, "metadata" => %{"detail" => detail}}]
             }} = resp.body

    assert detail =~ ":denied"
    refute Map.has_key?(resp.body, "result")
  end

  test "(c) a crashing provider answers -32007 and never the public card", %{agent: agent} do
    server = start_auth_server!(agent, &crashing_provider/2)

    resp = rpc!(server, "agent/getAuthenticatedExtendedCard", "valid-token-42")

    assert resp.status == 200

    assert %{"error" => %{"code" => -32_007, "data" => [%{"metadata" => %{"detail" => detail}}]}} =
             resp.body

    assert detail =~ "provider_raised"
    assert detail =~ "boom"
    refute Map.has_key?(resp.body, "result")
  end

  test "(c) the public card fetched from the same failing-provider server carries no admin skill", %{agent: agent} do
    server = start_auth_server!(agent, &failing_provider/2)

    refute "admin" in Enum.map(public_card_skills(server), & &1["id"])
  end

  # (d) no provider configured -> pinned refusal
  test "(d) no :extended_card provider configured is -32007 even for a verified caller", %{agent: agent} do
    server = start_auth_server!(agent, nil)

    resp = rpc!(server, "agent/getAuthenticatedExtendedCard", "valid-token-42")

    assert resp.status == 200

    assert %{"error" => %{"code" => -32_007, "data" => [%{"@type" => @error_info, "reason" => @ext_not_configured}]}} =
             resp.body

    refute Map.has_key?(resp.body, "result")
  end

  # (e) credential hygiene of the provider output
  test "(e) a credential-smuggling provider's output serves WITHOUT the internal keys", %{
    agent: agent
  } do
    server = start_auth_server!(agent, &credential_smuggling_provider/2)

    resp = rpc!(server, "agent/getAuthenticatedExtendedCard", "valid-token-42")

    assert resp.status == 200
    assert %{"result" => card} = resp.body

    # Positive pin: like task payloads, the provider's `{:ok, card}` output is
    # stripped of the internal keys ("a2a.auth", the owner key, the raw stream
    # ref) before it is encoded and served -- recursively, so a provider
    # cannot hide a credential inside a skill or nested metadata map either.
    assert card["metadata"] == %{}
    assert Enum.find(card["skills"], &(&1["id"] == "leak"))["metadata"] == %{}

    # The strip is key-targeted, not card-blanking: non-internal provider
    # output (including provider-injected extra fields) serves verbatim.
    assert card["secret"] == "s3cr3t"
    assert Enum.find(card["skills"], &(&1["id"] == "leak"))["description"] == "nested credential attempt"
  end

  test "(e) an honest provider's output serves unchanged", %{agent: agent} do
    # Fun-form provider: non-registered {m, f, a} MFAs are refused by the
    # CallbackRegistry court below, so this pin exercises the serve path.
    server = start_auth_server!(agent, &admin_card_provider/2)

    resp = rpc!(server, "agent/getAuthenticatedExtendedCard", "valid-token-42")

    assert resp.status == 200
    assert %{"result" => card} = resp.body

    assert Enum.find(card["skills"], &(&1["id"] == "admin"))["description"] == "for alice"
    refute Map.has_key?(card, "metadata")
    refute Map.has_key?(card, "secret")
    refute Map.has_key?(card, "a2a.auth")
    refute Map.has_key?(card, "ash_a2a.owner")
  end

  test "(e) the encoded public card handed to the provider carries no credential metadata", %{agent: agent} do
    parent = self()

    server =
      start_auth_server!(agent, fn _identity, card ->
        send(parent, {:provider_saw, card})
        {:ok, card}
      end)

    assert %{"result" => _} = rpc!(server, "agent/getAuthenticatedExtendedCard", "valid-token-42").body

    assert_received {:provider_saw, card}
    assert is_map(card)
    refute Map.has_key?(card, "metadata")
  end

  # -- CallbackRegistry closure on the {m, f, a} provider form -----------------

  test "{m, f, a} provider outside CallbackRegistry is -32007 and the callback is never executed", %{agent: agent} do
    :persistent_term.erase({__MODULE__, :forbidden_mfa_ran})

    server = start_auth_server!(agent, {__MODULE__, :forbidden_mfa_provider, []})

    resp = rpc!(server, "agent/getAuthenticatedExtendedCard", "valid-token-42")

    assert %{"error" => %{"code" => -32_007, "data" => [%{"metadata" => %{"detail" => detail}}]}} =
             resp.body

    assert detail =~ "callback_not_permitted"
    refute :persistent_term.get({__MODULE__, :forbidden_mfa_ran}, false)
  end
end
