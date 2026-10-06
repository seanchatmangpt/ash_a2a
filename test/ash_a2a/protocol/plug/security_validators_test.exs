defmodule AshA2A.Protocol.Plug.SecurityValidatorsTest do
  @moduledoc """
  Courts for the full A2A v1 security-scheme validator surface
  (`AshA2A.Protocol.Plug.SecurityValidators`).

  Per-scheme: a valid credential passes; expired / bad-issuer / bad-audience /
  scope-missing / bad-signature credentials are refused with the exact typed
  error code. API-key location enforcement is exercised end-to-end through a
  real `AshA2A.Protocol.Plug.Auth` pipeline (real `Plug.Test` conn). The OIDC
  and introspection courts run against REAL local HTTP servers (Bandit), not
  stubs.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias AshA2A.Protocol.Plug.Auth
  alias AshA2A.Protocol.Plug.SecurityValidators
  alias AshA2A.Protocol.SecurityScheme

  @now System.system_time(:second)

  # -- JWT helpers --------------------------------------------------------------

  defp b64(bin), do: Base.url_encode64(bin, padding: false)

  defp hs256_token(claims, secret, header \\ %{"alg" => "HS256", "typ" => "JWT"}) do
    signing_input =
      Enum.map_join([header, claims], ".", fn part ->
        part |> Jason.encode!() |> b64()
      end)

    sig = :crypto.mac(:hmac, :sha256, secret, signing_input)
    signing_input <> "." <> b64(sig)
  end

  defp claims(overrides \\ %{}) do
    Map.merge(
      %{"sub" => "user-1", "iss" => "https://auth.example.com", "aud" => "a2a-api", "exp" => @now + 600, "scope" => "a2a:read a2a:write"},
      overrides
    )
  end

  defp rsa_keypair do
    :public_key.generate_key({:rsa, 2048, 65_537})
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp jwk_from_key(key, kid) do
    {:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _} = key
    %{"kty" => "RSA", "kid" => kid, "n" => b64(:binary.encode_unsigned(n)), "e" => b64(:binary.encode_unsigned(e)), "alg" => "RS256", "use" => "sig"}
  end

  defp rs256_token(claims, key, kid, header_overrides \\ %{}) do
    header = Map.merge(%{"alg" => "RS256", "typ" => "JWT", "kid" => kid}, header_overrides)

    signing_input =
      Enum.map_join([header, claims], ".", fn part ->
        part |> Jason.encode!() |> b64()
      end)

    sig = :public_key.sign(:crypto.hash(:sha256, signing_input), :sha256, key)
    signing_input <> "." <> b64(sig)
  end

  # -- HS256 bearer -------------------------------------------------------------

  describe "validate_bearer/2 (HTTPAuth bearer, HS256)" do
    test "valid token passes with claims intact" do
      token = hs256_token(claims(), "s3cret")

      assert {:ok, result} = SecurityValidators.validate_bearer(token, secret: "s3cret", issuer: "https://auth.example.com", audience: "a2a-api")
      assert result["sub"] == "user-1"
      assert result[:scheme_kind] == :bearer
    end

    test "expired token refused" do
      token = hs256_token(claims(%{"exp" => @now - 3600}), "s3cret")

      assert {:error, %{code: :token_expired}} = SecurityValidators.validate_bearer(token, secret: "s3cret")
    end

    test "bad issuer refused" do
      token = hs256_token(claims(%{"iss" => "https://evil.example.com"}), "s3cret")

      assert {:error, %{code: :invalid_issuer, detail: %{expected: "https://auth.example.com"}}} =
               SecurityValidators.validate_bearer(token, secret: "s3cret", issuer: "https://auth.example.com")
    end

    test "bad audience refused" do
      token = hs256_token(claims(%{"aud" => "other-api"}), "s3cret")

      assert {:error, %{code: :invalid_audience}} = SecurityValidators.validate_bearer(token, secret: "s3cret", audience: "a2a-api")
    end

    test "audience list containing expected passes" do
      token = hs256_token(claims(%{"aud" => ["other-api", "a2a-api"]}), "s3cret")

      assert {:ok, _} = SecurityValidators.validate_bearer(token, secret: "s3cret", audience: "a2a-api")
    end

    test "missing scope refused" do
      token = hs256_token(claims(%{"scope" => "a2a:read"}), "s3cret")

      assert {:error, %{code: :insufficient_scope, detail: ["a2a:write"]}} =
               SecurityValidators.validate_bearer(token, secret: "s3cret", required_scopes: ["a2a:read", "a2a:write"])
    end

    test "scp claim honored as scope source" do
      token = hs256_token(claims(%{"scope" => nil, "scp" => "a2a:read a2a:write"}), "s3cret")

      assert {:ok, _} = SecurityValidators.validate_bearer(token, secret: "s3cret", required_scopes: ["a2a:write"])
    end

    test "bad signature refused" do
      token = hs256_token(claims(), "wrong-secret")

      assert {:error, %{code: :bad_signature}} = SecurityValidators.validate_bearer(token, secret: "s3cret")
    end

    test "malformed token refused" do
      assert {:error, %{code: :malformed_token}} = SecurityValidators.validate_bearer("not-a-jwt", secret: "s3cret")
      assert {:error, %{code: :invalid_token}} = SecurityValidators.validate_bearer(42, secret: "s3cret")
    end

    test "unsupported algorithm refused (alg none)" do
      header = %{"alg" => "none"}
      payload = Jason.encode!(claims())

      signing_input = b64(header) <> "." <> b64(payload)

      assert {:error, %{code: :unsupported_algorithm}} =
               SecurityValidators.validate_bearer(signing_input <> ".", secret: "s3cret")
    end

    test "required claims enforced" do
      token = hs256_token(%{"iss" => "https://auth.example.com"}, "s3cret")

      assert {:error, %{code: :missing_claim, detail: ["sub"]}} =
               SecurityValidators.validate_bearer(token, secret: "s3cret", required_claims: ["sub"])
    end
  end

  # -- API key ---------------------------------------------------------------------

  describe "validate_api_key/2" do
    test "matching key passes" do
      assert {:ok, %{scheme_kind: :key}} = SecurityValidators.validate_api_key("k-123", keys: ["k-123", "k-456"])
    end

    test "wrong key refused with typed error" do
      assert {:error, %{code: :invalid_api_key}} = SecurityValidators.validate_api_key("nope", keys: ["k-123"])
    end

    test "empty key set refuses everything (fail-closed)" do
      assert {:error, %{code: :invalid_api_key}} = SecurityValidators.validate_api_key("anything", keys: [])
    end
  end

  # -- OAuth2 ------------------------------------------------------------------------

  describe "validate_oauth2/2 (JWT path)" do
    test "delegates to bearer verification with scopes" do
      token = hs256_token(claims(%{"scope" => "a2a:read"}), "s3cret")

      assert {:error, %{code: :insufficient_scope}} =
               SecurityValidators.validate_oauth2(token, secret: "s3cret", required_scopes: ["a2a:write"])

      token2 = hs256_token(claims(), "s3cret")
      assert {:ok, %{scheme_kind: :oauth2}} = SecurityValidators.validate_oauth2(token2, secret: "s3cret")
    end
  end

  describe "validate_oauth2/2 (RFC 7662 introspection)" do
    setup do
      port = free_port()

      start_supervised({Bandit, plug: {__MODULE__.IntrospectionServer, []}, port: port})

      {:ok, introspection_url: "http://127.0.0.1:#{port}/introspect"}
    end

    test "active token with required scopes passes", %{introspection_url: url} do
      assert {:ok, claims} =
               SecurityValidators.validate_oauth2("tok-active", introspection_url: url, required_scopes: ["a2a:read"])

      assert claims["sub"] == "user-1"
      assert claims[:scheme_kind] == :oauth2
    end

    test "inactive token refused" do
      port = free_port()
      start_supervised({Bandit, plug: {__MODULE__.IntrospectionServer, inactive: true}, port: port})

      assert {:error, %{code: :token_inactive}} =
               SecurityValidators.validate_oauth2("tok-dead", introspection_url: "http://127.0.0.1:#{port}/introspect")
    end

    test "expired introspected token refused", %{introspection_url: url} do
      assert {:error, %{code: :token_expired}} =
               SecurityValidators.validate_oauth2("tok-expired", introspection_url: url)
    end

    test "missing scope refused", %{introspection_url: url} do
      assert {:error, %{code: :insufficient_scope, detail: ["a2a:admin"]}} =
               SecurityValidators.validate_oauth2("tok-active", introspection_url: url, required_scopes: ["a2a:admin"])
    end
  end

  # -- OpenID Connect ----------------------------------------------------------------

  describe "validate_oidc/2 (discovery + JWKS + RS256)" do
    setup do
      key = rsa_keypair()
      kid = "test-key-1"
      port = free_port()

      start_supervised({Bandit, plug: {__MODULE__.DiscoveryServer, [key: key, kid: kid, port: port]}, port: port})

      {:ok, discovery: "http://127.0.0.1:#{port}/.well-known/openid-configuration", key: key, kid: kid,
       jwk: jwk_from_key(key, kid)}
    end

    test "valid RS256 token via discovery passes", %{discovery: discovery, key: key, kid: kid} do
      token = rs256_token(claims(), key, kid)

      assert {:ok, result} =
               SecurityValidators.validate_oidc(token, discovery: discovery, issuer: "https://auth.example.com", audience: "a2a-api")

      assert result["sub"] == "user-1"
    end

    test "bad signature refused", %{discovery: discovery, kid: kid} do
      other_key = rsa_keypair()
      token = rs256_token(claims(), other_key, kid)

      assert {:error, %{code: :bad_signature}} = SecurityValidators.validate_oidc(token, discovery: discovery)
    end

    test "unknown kid refused", %{discovery: discovery, key: key} do
      token = rs256_token(claims(), key, "unknown-kid")

      assert {:error, %{code: :unknown_kid}} = SecurityValidators.validate_oidc(token, discovery: discovery)
    end

    test "expired token refused", %{discovery: discovery, key: key, kid: kid} do
      token = rs256_token(claims(%{"exp" => @now - 100}), key, kid)

      assert {:error, %{code: :token_expired}} = SecurityValidators.validate_oidc(token, discovery: discovery)
    end

    test "pre-loaded :jwks skips discovery", %{key: key, kid: kid, jwk: jwk} do
      token = rs256_token(claims(), key, kid)

      assert {:ok, _} = SecurityValidators.validate_oidc(token, jwks: %{"keys" => [jwk]})
    end

    test "discovery endpoint failure is a typed error" do
      # Nothing listening on this port (Bandit not started for 1).
      assert {:error, %{code: :discovery_error}} =
               SecurityValidators.validate_oidc("t", discovery: "http://127.0.0.1:1/.well-known/openid-configuration")
    end
  end

  # -- verifier/1 (Auth plug callback factory) -----------------------------------------

  describe "verifier/1" do
    test "unconfigured scheme refused fail-closed" do
      vf = SecurityValidators.verifier(%{"configured" => [secret: "s"]})

      assert {:error, %{code: :unconfigured_scheme}} = vf.("other", "token", nil)
    end

    test "kind dispatch per scheme name" do
      vf = SecurityValidators.verifier(%{"key" => [kind: :key, keys: ["k-1"]], "bearer" => [secret: "s"]})

      assert {:ok, _} = vf.("key", "k-1", nil)
      assert {:error, %{code: :invalid_api_key}} = vf.("key", "k-2", nil)
      assert {:error, %{code: :malformed_token}} = vf.("bearer", "garbage", nil)
    end
  end

  # -- End-to-end through AshA2A.Protocol.Plug.Auth ---------------------------------------

  describe "API-key location enforcement through Plug.Auth" do
    @schemes %{
      "key" => %SecurityScheme.APIKey{in: "header", name: "x-api-key"},
      "bearer" => %SecurityScheme.HTTPAuth{scheme: "bearer"}
    }

    defp auth_opts do
      Auth.init(
        schemes: @schemes,
        verify:
          SecurityValidators.verifier(%{
            "key" => [kind: :key, keys: ["k-123"]],
            "bearer" => [secret: "s3cret", issuer: "https://auth.example.com"]
          })
      )
    end

    test "api key in the declared header passes and stores identity" do
      conn =
        conn(:post, "/a2a", %{})
        |> put_req_header("x-api-key", "k-123")
        |> Auth.call(auth_opts())

      refute conn.halted
      assert %{scheme: "key"} = Auth.get_identity(conn)
    end

    test "api key supplied at the wrong location is 401, not a pass" do
      conn =
        conn(:post, "/a2a?key=k-123", %{})
        |> Auth.call(auth_opts())

      assert conn.status == 401
      assert conn.halted
      assert Jason.decode!(conn.resp_body) == %{"error" => "Unauthorized"}
    end

    test "wrong api key value is 401" do
      conn =
        conn(:post, "/a2a", %{})
        |> put_req_header("x-api-key", "wrong")
        |> Auth.call(auth_opts())

      assert conn.status == 401
      assert Jason.decode!(conn.resp_body) == %{"error" => "Unauthorized"}
    end

    test "valid bearer JWT passes through the same pipeline" do
      token = hs256_token(claims(%{"scope" => nil}), "s3cret")

      conn =
        conn(:post, "/a2a", %{})
        |> put_req_header("authorization", "Bearer #{token}")
        |> Auth.call(auth_opts())

      refute conn.halted
      assert %{scheme: "bearer", identity: identity} = Auth.get_identity(conn)
      assert identity["sub"] == "user-1"
    end

    test "expired bearer JWT is 401" do
      token = hs256_token(claims(%{"exp" => @now - 3600}), "s3cret")

      conn =
        conn(:post, "/a2a", %{})
        |> put_req_header("authorization", "Bearer #{token}")
        |> Auth.call(auth_opts())

      assert conn.status == 401
    end
  end

  # -- Real test servers (Chicago: no stubs) ----------------------------------------------

  defmodule IntrospectionServer do
    @behaviour Plug

    import Plug.Conn

    def init(opts), do: Map.new(opts)

    def call(conn, opts) do
      case {conn.path_info, conn.method} do
        {["introspect"], "POST"} ->
          {:ok, body, conn} = read_body(conn)
          %{"token" => token} = URI.decode_query(body)

          active = not Map.get(opts, :inactive, false)

          resp =
            if token == "tok-expired" do
              %{"active" => true, "sub" => "user-1", "scope" => "a2a:read a2a:write", "exp" => System.system_time(:second) - 100}
            else
              %{"active" => active, "sub" => "user-1", "scope" => "a2a:read a2a:write", "exp" => System.system_time(:second) + 600}
            end

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(resp))

        _ ->
          send_resp(conn, 404, "not found")
      end
    end
  end

  defmodule DiscoveryServer do
    @behaviour Plug

    import Plug.Conn

    def init(opts), do: Map.new(opts)

    def call(conn, opts) do
      case conn.path_info do
        [".well-known", "openid-configuration"] ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(%{"issuer" => "https://auth.example.com", "jwks_uri" => "http://127.0.0.1:#{opts.port}/jwks"}))

        ["jwks"] ->
          kid = opts.kid

          {:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _} = opts.key

          jwk = %{
            "kty" => "RSA",
            "kid" => kid,
            "n" => Base.url_encode64(:binary.encode_unsigned(n), padding: false),
            "e" => Base.url_encode64(:binary.encode_unsigned(e), padding: false),
            "alg" => "RS256",
            "use" => "sig"
          }

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(%{"keys" => [jwk]}))

        _ ->
          send_resp(conn, 404, "not found")
      end
    end
  end
end
