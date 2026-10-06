# Lane EV4 — Conference-sim venue access control over the REAL plug pipeline.
#
# Models the full G5/A2A v1 security-scheme surface as venue tiers:
#
#   apiKey (`x-badge` header)     = badge scan  → :expo tier
#   http bearer (HS256 JWT)       = session token → :workshop tier
#   oauth2 (RFC 7662 introspection
#    + client-credentials Basic)  = VIP all-access → :vip tier
#   openIdConnect (RS256 + OIDC
#    discovery → JWKS)            = SSO → :workshop tier
#
# Every court below runs over the real `AshA2A.Protocol.Plug.Auth` middleware
# with the real `AshA2A.Protocol.Plug.SecurityValidators` verifier, real
# Bandit HTTP servers (a real local RFC 7662/OIDC token server), real HS256/
# RS256 JWT signing via `:crypto`/`:public_key`, and real wire requests via
# Req. No Mock/mox/patch/monkeypatch anywhere in this file.
#
# Tier policy (venue law):
#   keynote stream  = all tiers
#   workshop task   = workshop + VIP
#   backstage task  = VIP only
#
# Cross-tier attempts are refused with a typed 403 wire envelope; credential
# failures are 401s with real RFC 7235 WWW-Authenticate challenges emitted by
# the real Auth plug; an expired VIP token introspects to an expired `exp`
# and must produce a fresh 401 challenge; an api-key presented in the wrong
# location (query param on a header scheme) is 401 by extraction law.
#
# Fixture modules live at TOP LEVEL of this file (never nested inside the
# test module: Elixir nests dotted module names under the enclosing module).

defmodule AshA2A.Test.ConferenceSim.Certs do
  @moduledoc """
  Real RSA keypair for the SSO (openIdConnect) scheme: RS256-signed SSO
  tokens are verified by the real validator against the JWKS the discovery
  path fetched from the real token server.
  """

  @key :public_key.generate_key({:rsa, 2048, 65_537})
  @kid "sso-key-1"

  def private_key, do: @key

  def kid, do: @kid

  def sso_public_jwk do
    {:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _} = @key

    %{
      "kty" => "RSA",
      "kid" => @kid,
      "n" => b64(:binary.encode_unsigned(n)),
      "e" => b64(:binary.encode_unsigned(e)),
      "alg" => "RS256",
      "use" => "sig"
    }
  end

  def sso_token(claims) do
    header = %{"alg" => "RS256", "typ" => "JWT", "kid" => @kid}

    signing_input =
      Enum.map_join([header, claims], ".", fn part ->
        part |> Jason.encode!() |> b64()
      end)

    sig = :public_key.sign(:crypto.hash(:sha256, signing_input), :sha256, @key)
    signing_input <> "." <> b64(sig)
  end

  defp b64(bin), do: Base.url_encode64(bin, padding: false)
end

defmodule AshA2A.Test.ConferenceSim.TokenServer do
  @moduledoc """
  Real local Bandit plug standing in as the venue's OAuth2/OIDC token server:

  - `POST /introspect` — RFC 7662 token introspection. Requires real HTTP
    Basic client credentials (`venue-server` / `venue-introspection-secret`);
    the token value self-describes its status so each court controls its own
    tokens without shared mutable state:
      `vip-active-<n>`  → active: true, exp = now + 3600, scope `venue:all`
      `vip-expired-<n>` → active: true, exp = now - 3600 (expired `exp` —
                          must be refused by the validator's expiry check,
                          surfacing as a 401 challenge at the wire)
      `vip-noscope-<n>` → active: true, unexpired, scope "" (insufficient)
      anything else     → active: false
  - `GET /.well-known/openid-configuration` — OIDC discovery document whose
    `jwks_uri` is derived from the request's own host/port.
  - `GET /jwks.json` — real JWKS serving the real RS256 public key.
  """

  import Plug.Conn

  @client_id "venue-server"
  @client_secret "venue-introspection-secret"

  @behaviour Plug

  @impl true
  def init(opts), do: Map.new(opts)

  @impl true
  def call(conn, _opts) do
    case {conn.method, conn.path_info} do
      {"POST", ["introspect"]} -> introspect(conn)
      {"GET", [".well-known", "openid-configuration"]} -> discovery(conn)
      {"GET", ["jwks.json"]} -> jwks(conn)
      _ -> json(conn, 404, %{"error" => "not_found"})
    end
  end

  defp introspect(conn) do
    with ["Basic " <> encoded] <- get_req_header(conn, "authorization"),
         {:ok, @client_id <> ":" <> @client_secret} <- Base.decode64(encoded) do
      {:ok, body, conn} = read_body(conn)
      %{"token" => token} = URI.decode_query(body)

      case token do
        "vip-active-" <> _ ->
          json(conn, 200, %{
            "active" => true,
            "sub" => "attendee-vip",
            "exp" => System.system_time(:second) + 3600,
            "scope" => "venue:all",
            "iss" => "https://venue.example"
          })

        "vip-expired-" <> _ ->
          json(conn, 200, %{
            "active" => true,
            "sub" => "attendee-vip",
            "exp" => System.system_time(:second) - 3600,
            "scope" => "venue:all"
          })

        "vip-noscope-" <> _ ->
          json(conn, 200, %{
            "active" => true,
            "sub" => "attendee-vip",
            "exp" => System.system_time(:second) + 3600,
            "scope" => ""
          })

        _ ->
          json(conn, 200, %{"active" => false})
      end
    else
      _ -> json(conn, 401, %{"error" => "invalid_client"})
    end
  end

  defp discovery(conn) do
    json(conn, 200, %{
      "issuer" => "https://venue.example",
      "jwks_uri" => "http://#{conn.host}:#{conn.port}/jwks.json"
    })
  end

  defp jwks(conn) do
    json(conn, 200, %{"keys" => [AshA2A.Test.ConferenceSim.Certs.sso_public_jwk()]})
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end
end

defmodule AshA2A.Test.ConferenceSim.Venue do
  @moduledoc """
  The venue endpoint: the REAL `AshA2A.Protocol.Plug.Auth` middleware (all
  four G5 schemes + real `SecurityValidators` verifier) followed by the
  venue's tier gate, which reads the real authenticated identity out of
  `conn.private[:a2a][:auth]` and enforces venue law (method x tier).
  """

  @behaviour Plug

  import Plug.Conn

  @session_secret "venue-session-secret-do-not-drink"

  # Venue law: method → tiers allowed.
  @method_tiers %{
    "keynote" => MapSet.new([:expo, :workshop, :vip]),
    "workshop" => MapSet.new([:workshop, :vip]),
    "backstage" => MapSet.new([:vip])
  }

  # Scheme name → venue tier.
  @scheme_tiers %{
    "badge" => :expo,
    "session_token" => :workshop,
    "vip" => :vip,
    "sso" => :workshop
  }

  @impl true
  def init(opts), do: Map.new(opts)

  @impl true
  def call(conn, %{token_base_url: base}) do
    auth_opts =
      AshA2A.Protocol.Plug.Auth.init(
        schemes: %{
          "badge" => %AshA2A.Protocol.SecurityScheme.APIKey{in: "header", name: "x-badge"},
          "session_token" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"},
          "vip" => %AshA2A.Protocol.SecurityScheme.OAuth2{flows: %{}},
          "sso" => %AshA2A.Protocol.SecurityScheme.OpenIDConnect{
            open_id_connect_url: base <> "/.well-known/openid-configuration"
          }
        },
        verify:
          AshA2A.Protocol.Plug.SecurityValidators.verifier(%{
            "badge" => [kind: :key, keys: [badge_id()]],
            "session_token" => [
              kind: :bearer,
              secret: @session_secret,
              issuer: "https://venue.example",
              audience: "venue-sessions",
              required_claims: ["sub", "exp"]
            ],
            "vip" => [
              kind: :oauth2,
              introspection_url: base <> "/introspect",
              client_id: "venue-server",
              client_secret: "venue-introspection-secret",
              required_scopes: ["venue:all"]
            ],
            "sso" => [
              kind: :oidc,
              discovery: base <> "/.well-known/openid-configuration",
              issuer: "https://venue.example",
              audience: "venue-sso",
              required_claims: ["sub", "exp"]
            ]
          })
      )

    conn = AshA2A.Protocol.Plug.Auth.call(conn, auth_opts)

    if conn.halted do
      conn
    else
      tier_gate(conn)
    end
  end

  # -- Venue tier gate ---------------------------------------------------------

  defp tier_gate(conn) do
    identity = AshA2A.Protocol.Plug.Auth.get_identity(conn)
    tier = Map.fetch!(@scheme_tiers, identity.scheme)
    method = method_of(conn)
    allowed? = method != nil and MapSet.member?(Map.fetch!(@method_tiers, method), tier)

    if allowed? do
      attendee = attendee_of(identity)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "granted" => true,
          "method" => method,
          "tier" => to_string(tier),
          "attendee" => attendee,
          "credentials_presented" => [identity.scheme]
        })
      )
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        403,
        Jason.encode!(%{
          "error" => %{
            "code" => "tier_access_denied",
            "method" => method,
            "tier" => to_string(tier)
          }
        })
      )
    end
  end

  defp attendee_of(identity) do
    case identity.identity do
      %{sub: sub} when is_binary(sub) -> sub
      %{"sub" => sub} -> sub
      _ -> "badge-holder"
    end
  end

  defp method_of(conn) do
    case conn.path_info do
      ["venue", method] when method in ["keynote", "workshop", "backstage"] -> method
      _ -> nil
    end
  end

  # -- Token minting (real :crypto HMAC signing) --------------------------------

  def session_token(extra_claims \\ %{}) do
    now = System.system_time(:second)

    claims =
      Map.merge(
        %{
          "sub" => "attendee-session",
          "iss" => "https://venue.example",
          "aud" => "venue-sessions",
          "exp" => now + 3600
        },
        extra_claims
      )

    header = %{"alg" => "HS256", "typ" => "JWT"}

    signing_input =
      Enum.map_join([header, claims], ".", fn part ->
        part |> Jason.encode!() |> Base.url_encode64(padding: false)
      end)

    sig = :crypto.mac(:hmac, :sha256, @session_secret, signing_input)
    signing_input <> "." <> Base.url_encode64(sig, padding: false)
  end

  def badge_id, do: "badge-BADGE-7741"

  def badge_header, do: {"x-badge", badge_id()}
end

defmodule AshA2A.Test.ConferenceSim.Sso do
  @moduledoc "SSO (openIdConnect) token minting via the real RSA keypair."

  defdelegate token(claims), to: AshA2A.Test.ConferenceSim.Certs, as: :sso_token

  def valid_token do
    AshA2A.Test.ConferenceSim.Certs.sso_token(%{
      "sub" => "attendee-sso",
      "iss" => "https://venue.example",
      "aud" => "venue-sso",
      "exp" => System.system_time(:second) + 3600,
      "scope" => "venue:sso"
    })
  end
end

defmodule AshA2A.Test.ConferenceSim.AuthTierCourt do
  @moduledoc """
  The courts. Each test starts its own real Bandit token server + venue
  server on OS-assigned ephemeral loopback ports and speaks real HTTP.
  """

  use ExUnit.Case, async: true

  defp get_resp_header(%Req.Response{headers: headers}, name) do
    Map.get(headers, name, [])
  end

  alias AshA2A.Test.ConferenceSim.{Sso, TokenServer, Venue}
  alias AshA2A.Test.EphemeralHttp

  @badge AshA2A.Test.ConferenceSim.Venue.badge_header()

  setup do
    token = EphemeralHttp.start!(TokenServer)
    venue = EphemeralHttp.start!({Venue, %{token_base_url: token.base_url}})

    %{
      token: token,
      venue: venue,
      vip: "vip-active-#{System.unique_integer([:positive])}",
      expired_vip: "vip-expired-#{System.unique_integer([:positive])}",
      noscope_vip: "vip-noscope-#{System.unique_integer([:positive])}",
      session: Venue.session_token(),
      sso: Sso.valid_token()
    }
  end

  # -- Tier-appropriate access ---------------------------------------------------

  test "badge scan (apiKey) grants the expo tier its keynote stream", c do
    resp = post(c.venue.base_url, "/venue/keynote", headers: [badge_header()])

    assert resp.status == 200
    assert body(resp) == %{
             "granted" => true,
             "method" => "keynote",
             "tier" => "expo",
             "attendee" => "badge-holder",
             "credentials_presented" => ["badge"]
           }
  end

  test "every scheme reaches the keynote stream (all tiers)", c do
    for auth <- [
          [badge_header()],
          [authorization("Bearer " <> c.session)],
          [authorization("Bearer " <> c.vip)],
          [authorization("Bearer " <> c.sso)]
        ] do
      resp = post(c.venue.base_url, "/venue/keynote", headers: auth)
      assert resp.status == 200, "scheme #{inspect(hd(auth))} failed: #{resp.status}"
      assert body(resp)["granted"] == true
    end
  end

  test "workshop task: session token and SSO in, badge out (403)", c do
    assert post(c.venue.base_url, "/venue/workshop", headers: [badge_header()]).status == 403

    resp = post(c.venue.base_url, "/venue/workshop", headers: [authorization("Bearer " <> c.session)])
    assert resp.status == 200
    assert body(resp)["tier"] == "workshop"

    resp = post(c.venue.base_url, "/venue/workshop", headers: [authorization("Bearer " <> c.sso)])
    assert resp.status == 200
    assert body(resp)["tier"] == "workshop"
  end

  test "backstage task: VIP only — badge and session both refused 403, VIP in", c do
    assert post(c.venue.base_url, "/venue/backstage", headers: [badge_header()]).status == 403
    assert post(c.venue.base_url, "/venue/backstage", headers: [authorization("Bearer " <> c.session)]).status ==
             403

    resp = post(c.venue.base_url, "/venue/backstage", headers: [authorization("Bearer " <> c.vip)])
    assert resp.status == 200
    assert body(resp) == %{
             "granted" => true,
             "method" => "backstage",
             "tier" => "vip",
             "attendee" => "attendee-vip",
             "credentials_presented" => ["vip"]
           }
  end

  test "cross-tier 403 carries the typed wire envelope, never a credential echo", c do
    resp = post(c.venue.base_url, "/venue/backstage", headers: [badge_header()])

    assert resp.status == 403
    assert body(resp) == %{
             "error" => %{"code" => "tier_access_denied", "method" => "backstage", "tier" => "expo"}
           }

    refute Jason.encode!(body(resp)) =~ Venue.badge_id()
  end

  # -- 401 challenge path ----------------------------------------------------------

  test "expired VIP token is challenged with 401 + Bearer WWW-Authenticate", c do
    resp = post(c.venue.base_url, "/venue/backstage", headers: [authorization("Bearer " <> c.expired_vip)])

    assert resp.status == 401
    challenges = get_resp_header(resp, "www-authenticate")
    assert Enum.any?(challenges, &String.starts_with?(&1, "Bearer realm="))
    assert body(resp) == %{"error" => "Unauthorized"}
  end

  test "VIP token without the venue:all scope is refused 401 (insufficient scope)", c do
    resp = post(c.venue.base_url, "/venue/backstage", headers: [authorization("Bearer " <> c.noscope_vip)])

    assert resp.status == 401
    assert get_resp_header(resp, "www-authenticate") != []
  end

  test "inactive VIP token (unknown token at introspection) is challenged 401", c do
    resp =
      post(c.venue.base_url, "/venue/backstage",
        headers: [authorization("Bearer vip-inactive-#{System.unique_integer([:positive])}")]
      )

    assert resp.status == 401
  end

  test "api-key presented in the wrong location (query on a header scheme) is 401", c do
    resp = post(c.venue.base_url, "/venue/keynote?x-badge=#{Venue.badge_id()}", headers: [])

    assert resp.status == 401
    assert body(resp) == %{"error" => "Unauthorized"}
    # The real Auth plug still emits the RFC 7235 challenges for the bearer
    # family even when the badge header was the (mis-)presented credential.
    assert get_resp_header(resp, "www-authenticate") != []
  end

  test "wrong badge value is a 401 identity refusal", c do
    resp = post(c.venue.base_url, "/venue/keynote", headers: [{"x-badge", "badge-forged-0000"}])

    assert resp.status == 401
  end

  test "no credentials at all is 401 with challenges", c do
    resp = post(c.venue.base_url, "/venue/keynote", headers: [])

    assert resp.status == 401
    assert Enum.any?(get_resp_header(resp, "www-authenticate"), &(&1 =~ "realm="))
  end

  # -- Mixed-scheme: same attendee, two schemes, no credential leakage --------------

  test "same attendee authenticates via badge for the expo floor and bearer for sessions", c do
    expo = post(c.venue.base_url, "/venue/keynote", headers: [badge_header()])
    sessions = post(c.venue.base_url, "/venue/keynote", headers: [authorization("Bearer " <> c.session)])

    assert expo.status == 200
    assert sessions.status == 200
    assert body(expo)["tier"] == "expo"
    assert body(sessions)["tier"] == "workshop"

    # Neither response leaks the other scheme's credential (or any credential).
    refute Jason.encode!(body(expo)) =~ c.session
    refute Jason.encode!(body(expo)) =~ Venue.badge_id()
    refute Jason.encode!(body(sessions)) =~ c.session
    refute Jason.encode!(body(sessions)) =~ Venue.badge_id()

    # And each request's identity is the one scheme only — the badge path never
    # carries the bearer credential and vice versa (single-scheme identity).
    assert body(expo)["credentials_presented"] == ["badge"]
    assert body(sessions)["credentials_presented"] == ["session_token"]
  end

  # -- Helpers -----------------------------------------------------------------------

  defp badge_header, do: @badge

  defp authorization(value), do: {"authorization", value}

  defp post(base_url, path, headers: headers) do
    Req.post!(base_url <> path, headers: headers, retry: false)
  end

  defp body(%Req.Response{body: body}) when is_map(body), do: body
  defp body(resp), do: Jason.decode!(resp.body)
end
