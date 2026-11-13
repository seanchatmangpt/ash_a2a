# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Y8.IdpPlug do
  @moduledoc false
  # Real local OIDC provider: discovery document + JWKS, counting hits.
  import Plug.Conn

  def init(agent), do: agent

  def call(conn, agent) do
    state = Agent.get(agent, & &1)

    case conn.request_path do
      "/.well-known/openid-configuration" ->
        Agent.update(agent, &update_in(&1, [:hits, :doc], fn n -> n + 1 end))

        json(conn, %{"issuer" => state.issuer, "jwks_uri" => state.base <> "/jwks"})

      "/jwks" ->
        Agent.update(agent, &update_in(&1, [:hits, :jwks], fn n -> n + 1 end))
        json(conn, state.jwks)

      _ ->
        send_resp(conn, 404, "")
    end
  end

  defp json(conn, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))
  end
end

defmodule AshA2A.Y8.LiveAgent do
  @moduledoc false
  use AshA2A.Protocol.Agent,
    name: "y8_live",
    description: "y8 uplink fixture",
    capabilities: %{streaming: true}

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _context),
    do: {:input_required, [AshA2A.Protocol.Part.Text.new("more?")]}
end

defmodule AshA2A.Y8.AuthSurfaceTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias AshA2A.Protocol.Plug.{ApiKeyVerifier, Auth, JWTVerifier, OIDCDiscovery}
  alias AshA2A.Protocol.SecurityScheme.APIKey
  alias AshA2A.Transport.Live

  defp b64(s), do: Base.url_encode64(s, padding: false)

  defp new_key do
    priv = :public_key.generate_key({:rsa, 2048, 65_537})
    {:RSAPrivateKey, _v, n, e, _d, _p, _q, _e1, _e2, _c, _o} = priv
    {priv, n, e}
  end

  defp jwk({_priv, n, e}, kid) do
    %{
      "kty" => "RSA",
      "kid" => kid,
      "alg" => "RS256",
      "use" => "sig",
      "n" => b64(:binary.encode_unsigned(n)),
      "e" => b64(:binary.encode_unsigned(e))
    }
  end

  defp rs256({priv, _, _}, kid, claims) do
    h = b64(Jason.encode!(%{"alg" => "RS256", "typ" => "JWT", "kid" => kid}))
    p = b64(Jason.encode!(claims))
    sig = :public_key.sign("#{h}.#{p}", :sha256, priv)
    "#{h}.#{p}.#{b64(sig)}"
  end

  defp claims(issuer),
    do: %{
      "iss" => issuer,
      "sub" => "y8-user",
      "aud" => "a2a",
      "exp" => System.system_time(:second) + 600
    }

  setup do
    OIDCDiscovery.clear()
    on_exit(&OIDCDiscovery.clear/0)

    key = new_key()

    {:ok, agent} =
      Agent.start_link(fn ->
        %{issuer: nil, base: nil, jwks: %{"keys" => [jwk(key, "k1")]}, hits: %{doc: 0, jwks: 0}}
      end)

    {:ok, server} =
      Bandit.start_link(
        plug: {AshA2A.Y8.IdpPlug, agent},
        port: 0,
        ip: :loopback,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    base = "http://127.0.0.1:#{port}"
    Agent.update(agent, &%{&1 | issuer: base, base: base})

    %{key: key, agent: agent, issuer: base}
  end

  defp hits(agent), do: Agent.get(agent, & &1.hits)

  describe "OIDC discovery" do
    test "resolves jwks_uri from the discovery document and fetches the JWKS", ctx do
      assert {:ok, uri} = OIDCDiscovery.jwks_uri(ctx.issuer)
      assert uri == ctx.issuer <> "/jwks"
      assert {:ok, %{"keys" => [%{"kid" => "k1"}]}} = OIDCDiscovery.jwks(ctx.issuer)
    end

    test "caches within the TTL and refetches after it", ctx do
      assert {:ok, _} = OIDCDiscovery.jwks(ctx.issuer)
      assert {:ok, _} = OIDCDiscovery.jwks(ctx.issuer)
      assert {:ok, _} = OIDCDiscovery.jwks(ctx.issuer)
      assert hits(ctx.agent) == %{doc: 1, jwks: 1}

      # ttl: 0 expires every entry
      assert {:ok, _} = OIDCDiscovery.jwks(ctx.issuer, ttl: 0)
      assert hits(ctx.agent) == %{doc: 2, jwks: 2}

      assert {:ok, _} = OIDCDiscovery.jwks(ctx.issuer, force: true)
      assert hits(ctx.agent) == %{doc: 3, jwks: 3}
    end

    test "issuer mismatch in the document is refused", ctx do
      Agent.update(ctx.agent, &%{&1 | issuer: "https://evil.example"})
      assert {:error, %{code: :discovery_error}} = OIDCDiscovery.discover(ctx.issuer)
    end

    test "unreachable issuer is a typed error" do
      assert {:error, %{code: :discovery_error}} = OIDCDiscovery.discover("http://127.0.0.1:1")
    end

    test "verifier_config feeds SecurityValidators.verify_jwt", ctx do
      assert {:ok, config} = OIDCDiscovery.verifier_config(ctx.issuer, audience: "a2a")

      assert {:ok, %{"sub" => "y8-user"}} =
               AshA2A.Protocol.Plug.SecurityValidators.verify_jwt(
                 rs256(ctx.key, "k1", claims(ctx.issuer)),
                 config
               )
    end
  end

  describe "API key verifier" do
    defp verifier(location, name \\ "x-api-key") do
      ApiKeyVerifier.new(
        scheme: %APIKey{in: location, name: name},
        keys: %{"svc-a" => "key-a-secret", "svc-b" => "key-b-secret"}
      )
    end

    test "header: accept, reject, missing" do
      v = verifier("header")

      assert {:ok, %{identity: "svc-a"}} =
               ApiKeyVerifier.authenticate(
                 v,
                 conn(:get, "/") |> put_req_header("x-api-key", "key-a-secret")
               )

      assert {:error, %{code: :invalid_api_key}} =
               ApiKeyVerifier.authenticate(
                 v,
                 conn(:get, "/") |> put_req_header("x-api-key", "wrong")
               )

      assert {:error, %{code: :missing_api_key}} = ApiKeyVerifier.authenticate(v, conn(:get, "/"))
    end

    test "query: accept, reject, missing" do
      v = verifier("query", "api_key")

      assert {:ok, %{identity: "svc-b"}} =
               ApiKeyVerifier.authenticate(v, conn(:get, "/?api_key=key-b-secret"))

      assert {:error, %{code: :invalid_api_key}} =
               ApiKeyVerifier.authenticate(v, conn(:get, "/?api_key=nope"))

      assert {:error, %{code: :missing_api_key}} =
               ApiKeyVerifier.authenticate(v, conn(:get, "/?other=1"))
    end

    test "cookie: accept, reject, missing" do
      v = verifier("cookie", "k")

      assert {:ok, %{identity: "svc-a"}} =
               ApiKeyVerifier.authenticate(
                 v,
                 conn(:get, "/") |> put_req_header("cookie", "k=key-a-secret")
               )

      assert {:error, %{code: :invalid_api_key}} =
               ApiKeyVerifier.authenticate(
                 v,
                 conn(:get, "/") |> put_req_header("cookie", "k=bad")
               )

      assert {:error, %{code: :missing_api_key}} = ApiKeyVerifier.authenticate(v, conn(:get, "/"))
    end

    test "a key from the wrong location is not accepted" do
      v = verifier("header")

      assert {:error, %{code: :missing_api_key}} =
               ApiKeyVerifier.authenticate(v, conn(:get, "/?x-api-key=key-a-secret"))
    end

    test "plain key list verifies without identity" do
      v = ApiKeyVerifier.new(scheme: %APIKey{in: "header", name: "x-api-key"}, keys: ["only"])
      assert {:ok, %{authenticated: true, identity: nil}} = ApiKeyVerifier.verify(v, "only")
      assert {:error, %{code: :invalid_api_key}} = ApiKeyVerifier.verify(v, "ONLY")
    end

    test "wired into the Auth plug through verify_fun: 200-path vs 401" do
      scheme = %APIKey{in: "header", name: "x-api-key"}

      opts =
        Auth.init(
          schemes: %{"key" => scheme},
          security: [%{"key" => []}],
          verify: ApiKeyVerifier.verify_fun(%{"key" => verifier("header")})
        )

      ok = conn(:post, "/") |> put_req_header("x-api-key", "key-b-secret") |> Auth.call(opts)
      refute ok.halted
      assert Auth.get_identity(ok)

      bad = conn(:post, "/") |> put_req_header("x-api-key", "nope") |> Auth.call(opts)
      assert bad.halted and bad.status == 401

      none = conn(:post, "/") |> Auth.call(opts)
      assert none.halted and none.status == 401
    end
  end

  describe "live uplink ctx scrub" do
    setup do
      unless Process.whereis(Live.Registry), do: start_supervised!(Live.Supervisor)

      name = :"y8_agent_#{System.unique_integer([:positive])}"
      start_supervised!(%{id: name, start: {AshA2A.Y8.LiveAgent, :start_link, [[name: name]]}})
      %{agent: name}
    end

    defp auth(sub), do: %{"a2a.auth" => %{identity: %{sub: sub}, scheme: "bearer"}}

    defp req(text, extra \\ %{}) do
      %{
        "sendMessage" => %{
          "message" =>
            Map.merge(
              %{
                "messageId" => "m-#{System.unique_integer([:positive])}",
                "role" => "user",
                "parts" => [%{"text" => text}]
              },
              extra
            )
        }
      }
    end

    test "scrub_uplink_ctx drops reserved keys and keeps the authenticated principal" do
      ctx =
        Live.scrub_uplink_ctx(%{
          metadata: auth("alice"),
          uplink: %{
            metadata: Map.merge(auth("mallory"), %{"ash_a2a.owner" => "sub:mallory", "ok" => 1})
          }
        })

      assert Live.principal(ctx) == "sub:alice"
      assert ctx.metadata["ok"] == 1
      refute ctx.metadata["ash_a2a.owner"]
    end

    test "forged a2a.auth in uplink metadata alone yields no principal" do
      ctx = Live.scrub_uplink_ctx(%{metadata: %{}, uplink: %{metadata: auth("mallory")}})
      assert Live.principal(ctx) == :anonymous
    end

    test "forged a2a.auth cannot take over another principal's task", %{agent: agent} do
      assert {:ack, task} = Live.uplink_call(agent, %{metadata: auth("alice")}, req("ask"))
      id = Map.get(task, :id)
      assert is_binary(id)

      forged = %{metadata: auth("mallory"), uplink: %{metadata: auth("alice")}}
      assert {:error, _} = Live.uplink_call(agent, forged, req("more", %{"taskId" => id}))

      # control: the real owner continues
      assert {:ack, _} =
               Live.uplink_call(agent, %{metadata: auth("alice")}, req("more", %{"taskId" => id}))
    end
  end
end
