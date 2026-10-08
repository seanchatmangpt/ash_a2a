# Lane EV10 — Conference-sim red team: the hostile attendee at event scale.
#
# Every AT5/EV-class attack is run against the REAL pipeline, with the attack
# scripts living in the court itself (no mocks, no patches — real :crypto
# signing, real Bandit token server, real JWKS fetch, real gRPC server):
#
#   1. badge forgery   — attendee signs an SSO token with their OWN RSA key;
#                        the venue fetches the real JWKS and refuses (401).
#   2. badge replay    — a captured valid badge JWT replayed after `exp`
#                        expires → 401 (real claim validation).
#   3. tier escalation — a :general (expo) badge on the workshop method → 403;
#                        CRLF injection in `x-badge` → refused, nothing
#                        smuggled into the header set.
#   4. session hijack  — attendee B names attendee A's task id on every
#                        task-naming method → owner-scope refusal.
#   5. push hijack     — B registers a push config on A's task → refusal.
#   6. stream bombing  — 200 concurrent resubscribe connections against the
#                        venue; the venue survives (all served or cleanly
#                        capped, never a crash), and honest traffic still
#                        works afterwards.
#   7. metadata clobber re-check — attacker params carrying "a2a.auth" /
#                        "ash_a2a.owner" keys are stripped under event
#                        conditions (the AT5 fix holds at scale).
#   8. gRPC unauthenticated venue access with the auth interceptor configured
#                        → UNAUTHENTICATED(16), and an honest attendee on the
#                        same wire still gets served.
#
# Every court pairs the attack with its honest positive control: the
# legitimate action still works after (or beside) the attack.
#
# Fixture modules live at TOP LEVEL of this file (never nested inside the
# test module: Elixir nests dotted module names under the enclosing module).

ExUnit.start()

defmodule AshA2A.ConferenceSim.RedTeam.RSA do
  @moduledoc """
  Real RSA keypairs: the venue SSO key (published via the real JWKS endpoint)
  and the attacker's own key (published nowhere — that is the whole point of
  attack 1).
  """

  @venue_key :public_key.generate_key({:rsa, 2048, 65_537})
  @attacker_key :public_key.generate_key({:rsa, 2048, 65_537})
  @kid "venue-sso-key-1"
  @attacker_kid "attendee-forged-key-1"

  def venue_key, do: @venue_key
  def attacker_key, do: @attacker_key
  def kid, do: @kid
  def attacker_kid, do: @attacker_kid

  def venue_public_jwk do
    {:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _} = @venue_key
    jwk(n, e, @kid)
  end

  def attacker_public_jwk do
    {:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _} = @attacker_key
    jwk(n, e, @attacker_kid)
  end

  def rs256_token(claims, key, kid) do
    header = %{"alg" => "RS256", "typ" => "JWT", "kid" => kid}

    signing_input =
      Enum.map_join([header, claims], ".", fn part ->
        part |> Jason.encode!() |> b64()
      end)

    sig = :public_key.sign(:crypto.hash(:sha256, signing_input), :sha256, key)
    signing_input <> "." <> b64(sig)
  end

  defp jwk(n, e, kid) do
    %{
      "kty" => "RSA",
      "kid" => kid,
      "n" => b64(:binary.encode_unsigned(n)),
      "e" => b64(:binary.encode_unsigned(e)),
      "alg" => "RS256",
      "use" => "sig"
    }
  end

  defp b64(bin), do: Base.url_encode64(bin, padding: false)
end

defmodule AshA2A.ConferenceSim.RedTeam.TokenServer do
  @moduledoc """
  Real local Bandit plug: the venue SSO provider. Serves the OIDC discovery
  document and the real JWKS containing ONLY the venue key — the attacker's
  key is never published, so a forged token must fail real signature
  verification.
  """

  import Plug.Conn
  @behaviour Plug

  @impl true
  def init(opts), do: Map.new(opts)

  @impl true
  def call(conn, _opts) do
    case {conn.method, conn.path_info} do
      {"GET", [".well-known", "openid-configuration"]} -> discovery(conn)
      {"GET", ["jwks.json"]} -> jwks(conn)
      _ -> send_resp(conn, 404, "not found")
    end
  end

  defp discovery(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      200,
      Jason.encode!(%{
        "issuer" => "https://venue.example",
        "jwks_uri" => "http://#{conn.host}:#{conn.port}/jwks.json"
      })
    )
    |> halt()
  end

  defp jwks(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{"keys" => [AshA2A.ConferenceSim.RedTeam.RSA.venue_public_jwk()]}))
    |> halt()
  end
end

defmodule AshA2A.ConferenceSim.RedTeam.Venue do
  @moduledoc """
  The venue gate over the REAL `AshA2A.Protocol.Plug.Auth` middleware with
  the real `AshA2A.Protocol.Plug.SecurityValidators` verifier: badge
  (api key, `x-badge` header), session badge (bearer HS256 JWT) and SSO
  (RS256 via real OIDC discovery + JWKS fetch).

  Venue law: keynote = every tier, workshop = session/SSO badge holders,
  backstage = VIP only (no VIP credential is ever minted in this file, so
  any backstage attempt is a 403 by construction). The gate reads the real
  authenticated identity out of `conn.private[:a2a][:auth]` and answers
  200 granted / 403 tier_access_denied / 401 unauthorized.
  """

  @behaviour Plug

  import Plug.Conn

  @session_secret "red-team-venue-session-secret"
  @badge_id "badge-BADGE-7741"

  @method_tiers %{
    "keynote" => MapSet.new([:general, :session, :sso]),
    "workshop" => MapSet.new([:session, :sso]),
    "backstage" => MapSet.new([:vip])
  }

  @impl true
  def init(opts), do: Map.new(opts)

  @impl true
  def call(conn, %{discovery_url: discovery_url}) do
    auth_opts =
      AshA2A.Protocol.Plug.Auth.init(
        schemes: %{
          "badge" => %AshA2A.Protocol.SecurityScheme.APIKey{in: "header", name: "x-badge"},
          "session" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"},
          "sso" => %AshA2A.Protocol.SecurityScheme.OpenIDConnect{
            open_id_connect_url: discovery_url
          }
        },
        verify:
          AshA2A.Protocol.Plug.SecurityValidators.verifier(%{
            "badge" => [kind: :key, keys: [@badge_id]],
            "session" => [
              kind: :bearer,
              secret: @session_secret,
              issuer: "https://venue.example",
              audience: "venue-sessions",
              required_claims: ["sub", "exp"]
            ],
            "sso" => [
              kind: :oidc,
              discovery: discovery_url <> "/.well-known/openid-configuration",
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

  defp tier_gate(conn) do
    identity = AshA2A.Protocol.Plug.Auth.get_identity(conn)
    tier = tier_of(identity.scheme)
    method = method_of(conn)

    if method && MapSet.member?(Map.fetch!(@method_tiers, method), tier) do
      attendee = attendee_of(identity)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "granted" => true,
          "method" => method,
          "tier" => to_string(tier),
          "attendee" => attendee
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

  defp tier_of("badge"), do: :general
  defp tier_of("session"), do: :session
  defp tier_of("sso"), do: :sso

  defp attendee_of(%{identity: %{sub: sub}}) when is_binary(sub), do: sub
  defp attendee_of(%{identity: %{"sub" => sub}}), do: sub
  # API-key badges carry no claims; the venue knows this badge id's holder.
  defp attendee_of(_), do: "badge-holder-7741"

  defp method_of(conn) do
    case conn.path_info do
      ["venue", method] when method in ["keynote", "workshop", "backstage"] -> method
      _ -> nil
    end
  end

  # -- credential minting (real :crypto HMAC) ---------------------------------

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

  def badge_id, do: @badge_id
  def badge_header, do: {"x-badge", @badge_id}
end

defmodule AshA2A.ConferenceSim.RedTeam.Converse do
  @moduledoc """
  Real fixture resource for the owner-scope attacks (4/5/7): one generic
  `:converse` action requiring `:say`, so a `message/send` without structured
  arguments pauses the real task at TASK_STATE_INPUT_REQUIRED — a live,
  continuable task an attacker can go after.
  """

  use Ash.Resource,
    domain: AshA2A.ConferenceSim.RedTeam.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:label, :string, public?: true)
  end

  actions do
    defaults([:read])

    action :converse, :map do
      argument(:say, :string, allow_nil?: false)

      run(fn input, _context ->
        {:ok, %{say: input.arguments.say}}
      end)
    end
  end

  a2a do
    skill(:converse, :converse, consequence: :observe)
  end
end

defmodule AshA2A.ConferenceSim.RedTeam.Domain do
  @moduledoc "Real fixture domain for the red-team fixture resource."

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.ConferenceSim.RedTeam.Converse)
  end
end

defmodule AshA2A.ConferenceSim.RedTeam.Agent do
  @moduledoc """
  Real `AshA2A.Agent` GenServer (owner-keyed tasks, auth rebinding) with the
  v1.0 `require_authenticated_caller: true` default pinned explicitly.
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.ConferenceSim.RedTeam.Converse,
    name: "conference_red_team_agent",
    require_authenticated_caller: true,
    execution: [mode: :inline]
end

defmodule AshA2A.ConferenceSim.RedTeam.GRPCHandler do
  @moduledoc """
  Real `AshA2A.Protocol.JSONRPC` handler over the real EchoAgent fixture
  (local copy of the delegation shape so this file does not depend on another
  test file's module at runtime — the EchoAgent fixture itself IS shared
  compiled support code, not a mock).
  """

  @behaviour AshA2A.Protocol.JSONRPC

  alias AshA2A.Test.Fixture.EchoAgent

  @impl AshA2A.Protocol.JSONRPC
  def handle_send(message, _params, %{agent: agent}) do
    AshA2A.Protocol.call(agent, message)
  end

  @impl AshA2A.Protocol.JSONRPC
  def handle_get(task_id, _params, %{agent: agent}) do
    case EchoAgent.get_task(agent, task_id) do
      {:ok, task} -> {:ok, task}
      {:error, :not_found} -> {:error, %AshA2A.Protocol.JSONRPC.Error{code: -32001, message: "task not found: #{task_id}"}}
    end
  end

  @impl AshA2A.Protocol.JSONRPC
  def handle_cancel(task_id, _params, %{agent: agent}) do
    case EchoAgent.cancel(agent, task_id) do
      :ok -> EchoAgent.get_task(agent, task_id)
      {:error, :not_found} -> {:error, %AshA2A.Protocol.JSONRPC.Error{code: -32001, message: "task not found: #{task_id}"}}
      {:error, reason} -> {:error, %AshA2A.Protocol.JSONRPC.Error{code: -32002, message: inspect(reason)}}
    end
  end
end

defmodule AshA2A.ConferenceSim.RedTeam.GRPCVerify do
  @moduledoc """
  Real HS256 JWT verification for the gRPC interceptor seam — header check,
  constant-time HMAC-SHA256 signature comparison, `sub` required. Real
  `:crypto`, no JWT library, no mocks.
  """

  @secret "red-team-grpc-hs256-secret"

  def secret, do: @secret

  def verify(_scheme, credential, _conn) do
    with [header_b64, payload_b64, sig_b64] <- String.split(credential, ".", parts: 3),
         {:ok, %{"alg" => "HS256"}} <- Jason.decode(Base.url_decode64!(header_b64)),
         {:ok, claims} <- Jason.decode(Base.url_decode64!(payload_b64)),
         signing_input = header_b64 <> "." <> payload_b64,
         :ok <- check_sig(signing_input, sig_b64) do
      if is_binary(claims["sub"]) and claims["sub"] != "" do
        {:ok, %{sub: claims["sub"]}}
      else
        {:error, "missing sub claim"}
      end
    else
      _ -> {:error, "invalid JWT"}
    end
  end

  defp check_sig(signing_input, sig_b64) do
    expected = :crypto.mac(:hmac, :sha256, @secret, signing_input)
    sig = Base.url_decode64!(sig_b64, padding: false)

    if Plug.Crypto.secure_compare(sig, expected), do: :ok, else: {:error, "bad signature"}
  end
end

defmodule AshA2A.ConferenceSim.RedTeam.Receiver do
  @moduledoc false
  # Real webhook receiver forwarding each push-registration body to the test
  # process (the attacks must never reach it; the honest positive control may).
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, %{test: test}) do
    {:ok, body, conn} = read_body(conn)
    send(test, {:webhook, body})
    send_resp(conn, 200, "")
  end
end

defmodule AshA2A.ConferenceSim.RedTeam.SSEPipeline do
  @moduledoc false
  # Real plug pipeline (bearer auth -> wrapper transport plug) on a real
  # Bandit listener, so the flood's resubscribes are real streaming HTTP.
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, %{auth: auth, plug: plug, user: user}) do
    conn
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> user)
    |> AshA2A.Protocol.Plug.Auth.call(auth)
    |> AshA2A.A2ATransport.Plug.call(plug)
  end
end

defmodule AshA2A.ConferenceSim.RedTeamCourt do
  @moduledoc """
  The red-team courts. `async: false`: the gRPC court drives real
  Application env on the shared endpoint module.
  """

  use ExUnit.Case, async: false

  alias AshA2A.A2ATransport.Plug, as: TransportPlug
  alias AshA2A.ConferenceSim.RedTeam.{Agent, RSA, TokenServer, Venue}
  alias AshA2A.Test.EphemeralHttp
  alias AshA2A.ConferenceSim.RedTeam.GRPCVerify
  alias AshA2A.ConferenceSim.RedTeam.Receiver
  alias AshA2A.ConferenceSim.RedTeam.SSEPipeline
  alias AshA2A.Protocol.{Message, Part}
  alias Lf.A2a.V1, as: Pb

  @internal_keys ["a2a.auth", "ash_a2a.owner"]
  @metadata_internal_keys ["a2a.auth", "ash_a2a.owner", "stream"]

  # ---------------------------------------------------------------------------
  # Venue credential attacks (1-3): real Bandit token server + real Auth plug
  # ---------------------------------------------------------------------------

  describe "venue credential attacks" do
    setup do
      http = EphemeralHttp.start!({TokenServer, %{}})
      %{venue_url: http.base_url}
    end

    test "1a badge forgery: attacker-signed SSO token fails against the real venue JWKS",
         %{venue_url: venue_url} do
      now = System.system_time(:second)

      forged =
        RSA.rs256_token(
          %{
            "sub" => "attendee-vip-hopeful",
            "iss" => "https://venue.example",
            "aud" => "venue-sso",
            "exp" => now + 3600
          },
          RSA.attacker_key(),
          RSA.attacker_kid()
        )

      conn =
        venue_get(venue_url, ["venue", "keynote"], [{"authorization", "Bearer " <> forged}])

      assert conn.status == 401
      assert conn.resp_body =~ "Unauthorized"

      # Nothing about the forgery minted a VIP tier or a backstage grant.
      refute conn.resp_body =~ "granted"
    end

    test "1b positive control: an honest SSO token signed by the venue key is served",
         %{venue_url: venue_url} do
      now = System.system_time(:second)

      honest =
        RSA.rs256_token(
          %{
            "sub" => "attendee-honest",
            "iss" => "https://venue.example",
            "aud" => "venue-sso",
            "exp" => now + 3600
          },
          RSA.venue_key(),
          RSA.kid()
        )

      conn = venue_get(venue_url, ["venue", "keynote"], [{"authorization", "Bearer " <> honest}])

      assert %{"granted" => true, "tier" => "sso", "attendee" => "attendee-honest"} =
               Jason.decode!(conn.resp_body)
    end

    test "2a badge replay: a captured valid badge JWT replayed after expiry is refused",
         %{venue_url: venue_url} do
      # "Capture" a badge JWT minted by the venue signer; by replay time its
      # `exp` lies far outside the validator's 60s clock-skew allowance.
      captured =
        Venue.session_token(%{"exp" => System.system_time(:second) - 3_600})

      conn =
        venue_get(venue_url, ["venue", "keynote"], [
          {"authorization", "Bearer " <> captured}
        ])

      assert conn.status == 401
      assert conn.resp_body =~ "Unauthorized"

      # The refusal is a real expiry refusal: the identical token minted with
      # a fresh exp is served — same signer, same claims, only `exp` differs.
      fresh = Venue.session_token(%{"sub" => "attendee-session"})
      conn_ok = venue_get(venue_url, ["venue", "keynote"], [{"authorization", "Bearer " <> fresh}])

      assert %{"granted" => true, "tier" => "session"} = Jason.decode!(conn_ok.resp_body)
    end

    test "3a tier escalation: a :general badge on the workshop method is a 403",
         %{venue_url: venue_url} do
      conn = venue_get(venue_url, ["venue", "workshop"], [Venue.badge_header()])

      assert conn.status == 403

      assert %{"error" => %{"code" => "tier_access_denied", "method" => "workshop",
                            "tier" => "general"}} = Jason.decode!(conn.resp_body)

      # The same badge on the keynote (which its tier allows) is served — the
      # 403 is the tier law, not a broken badge.
      conn_ok = venue_get(venue_url, ["venue", "keynote"], [Venue.badge_header()])

      assert %{"granted" => true, "tier" => "general"} = Jason.decode!(conn_ok.resp_body)
    end

    test "3b header injection: CRLF in x-badge is refused and nothing is smuggled",
         %{venue_url: venue_url} do
      malicious = Venue.badge_id() <> "\r\nX-Injected: pwned"

      conn = venue_get(venue_url, ["venue", "keynote"], [{"x-badge", malicious}])

      # The credential fails the real constant-time key comparison → 401.
      assert conn.status == 401

      # The CRLF payload never became a real header anywhere in the response.
      refute Enum.any?(conn.resp_headers, fn {name, _} ->
               name in ["x-injected", "injected"]
             end)
    end
  end

  # ---------------------------------------------------------------------------
  # Owner-scope attacks (4/5/7) + stream bombing (6): real wrapper transport
  # ---------------------------------------------------------------------------

  describe "session hijack and metadata attacks on the wrapper transport" do
    setup :wrapper_transport

    test "4 session hijack: attendee B is refused on every task-naming method on A's task",
         ctx do
      %{"id" => task_id} = create_task(ctx, "alice")

      foreign_attempts = [
        {"tasks/get", %{"id" => task_id}},
        {"tasks/cancel", %{"id" => task_id}},
        {"tasks/resubscribe", %{"id" => task_id}},
        {"message/send", %{"message" => message(%{"taskId" => task_id})}},
        {"message/stream", %{"message" => message(%{"taskId" => task_id})}}
      ]

      for {method, params} <- foreign_attempts do
        assert_task_not_found(rpc(ctx, "bob", method, params), "#{method} as bob")
      end

      # Positive control: alice still owns and reads her task after the attack.
      assert %{"result" => %{"id" => ^task_id, "status" => %{"state" => "TASK_STATE_INPUT_REQUIRED"}}} =
               rpc(ctx, "alice", "tasks/get", %{"id" => task_id})
    end

    test "5 push hijack: B cannot register a push config on A's task", ctx do
      %{"id" => task_id} = create_task(ctx, "alice")

      assert_task_not_found(
        rpc(ctx, "bob", "tasks/pushNotificationConfig/set", %{
          "taskId" => task_id,
          "pushNotificationConfig" => %{"url" => ctx.hook}
        }),
        "push set as bob"
      )

      assert_task_not_found(
        rpc(ctx, "bob", "tasks/pushNotificationConfig/get", %{"id" => task_id}),
        "push get as bob"
      )

      # The hijack registered nothing: alice's own config store is empty and
      # her task untouched.
      assert %{"result" => result} =
               rpc(ctx, "alice", "tasks/pushNotificationConfig/list", %{"id" => task_id})

      assert result == []

      # Positive control: alice registers a push config on her own task.
      assert %{"result" => _} =
               rpc(ctx, "alice", "tasks/pushNotificationConfig/set", %{
                 "taskId" => task_id,
                 "pushNotificationConfig" => %{"url" => ctx.hook}
               })
    end

    @tag timeout: 180_000
    test "6 stream bombing: 200 concurrent resubscribe connections and the venue survives",
         ctx do
      # The attacker mints their OWN live (INPUT_REQUIRED) task so every flood
      # connection is a REAL subscribed stream (not an instant foreign-task
      # refusal) on a real Bandit listener; the venue closes each stream at the
      # short idle, and the client receive_timeout is a backstop.
      %{"id" => task_id} = create_task(ctx, "attacker")

      sse =
        EphemeralHttp.start!({SSEPipeline, %{auth: ctx.auth, plug: ctx.plug, user: "attacker"}})

      parent = self()

      flood =
        Task.async_stream(
          1..200,
          fn _ ->
            try do
              resp =
                Req.post!(sse.base_url,
                  json: %{
                    "jsonrpc" => "2.0",
                    "id" => System.unique_integer([:positive]),
                    "method" => "tasks/resubscribe",
                    "params" => %{"id" => task_id}
                  },
                  headers: [{"content-type", "application/json"}],
                  retry: false,
                  receive_timeout: 2_000,
                  into: fn {:data, data}, acc ->
                    send(parent, {:flood_chunk, byte_size(data)})
                    {:cont, acc}
                  end
                )

              {:ok, resp.status}
            rescue
              # A client-side timeout/disconnect is a clean refusal at the
              # client edge — the venue never crashed the connection.
              _ -> {:refused, :client_timeout}
            end
          end,
          max_concurrency: 32,
          timeout: 170_000
        )

      results = Enum.to_list(flood)

      # Every connection was served or cleanly capped — never a crash/5xx.
      Enum.each(results, fn
        {:ok, {:ok, status}} -> assert status in [200, 429, 503]
        {:ok, {:refused, :client_timeout}} -> :ok
        {:exit, reason} -> flunk("flood connection crashed: #{inspect(reason)}")
      end)

      assert length(results) == 200

      # The venue process tree is alive after the flood.
      assert Process.alive?(ctx.transport_pid)
      assert Process.alive?(ctx.agent_pid)

      # Positive control: an honest attendee is still served after the attack.
      %{"id" => honest_task} = create_task(ctx, "alice")

      assert %{"result" => %{"id" => ^honest_task}} =
               rpc(ctx, "alice", "tasks/get", %{"id" => honest_task})
    end

    test "7 metadata clobber re-check: the AT5 params.metadata scrub holds under event conditions",
         ctx do
      forged_metadata = %{
        "a2a.auth" => %{"forged" => "credential"},
        "ash_a2a.owner" => "bob",
        "seat" => "hall-b"
      }

      # -- The AT5 surface (params-level metadata): scrubbed, dead on arrival.

      # Bob attacks with a bogus foreign taskId carrying forged internal keys
      # at PARAMS level; ownership still derives from the verified identity.
      assert_task_not_found(
        rpc(ctx, "bob", "message/send", %{
          "message" => message(%{"taskId" => "tsk-forged-000"}),
          "metadata" => forged_metadata
        }),
        "forged params.metadata on foreign task"
      )

      %{"id" => bob_task} =
        send_task(ctx, "bob", %{
          "message" => message(),
          "metadata" => forged_metadata
        })

      response = rpc(ctx, "bob", "tasks/get", %{"id" => bob_task})

      # No internal key survives anywhere in the published payload.
      assert_no_internal_keys(response, "$")

      # Bob's forged owner claim changed nothing: the task is still bob's, and
      # alice cannot see it.
      assert_task_not_found(rpc(ctx, "alice", "tasks/get", %{"id" => bob_task}), "alice on bob task")

      # Positive control: bob's benign params metadata ("seat") still rides.
      assert get_in(response, ["result", "metadata", "seat"]) == "hall-b"

      # -- CLOSED FINDING EV10-F1 (publication gap, message-level metadata echo):
      #
      # The AT5 fix scrubs PARAMS-level metadata; caller-supplied
      # message.metadata keys ("a2a.auth", "ash_a2a.owner") also ride inside the
      # stored message and are echoed back in the task's history
      # (message/send response AND tasks/get). Ownership.strip_wire/1 and
      # strip_task/1 now scrub every history message's metadata as well, so
      # the echo below is asserted ABSENT — the permanent court for EV10-F1.
      %{"id" => echo_task} =
        send_task(ctx, "bob", %{
          "message" => skill_message("converse", forged_metadata)
        })

      echo = rpc(ctx, "bob", "tasks/get", %{"id" => echo_task})

      # Permanent court: no internal key may appear anywhere in the echoed
      # task — task metadata, history message metadata, or any nested map.
      encoded = Jason.encode!(echo)
      refute encoded =~ "ash_a2a.owner", "owner key echoed in task history"
      refute encoded =~ "a2a.auth", "auth key echoed in task history"

      # Benign caller metadata inside history messages still rides.
      history_meta =
        echo
        |> get_in(["result", "history"])
        |> Enum.flat_map(fn m -> Map.get(m, "metadata") |> List.wrap() end)

      assert Enum.any?(history_meta, &(&1["skill"] == "converse")),
             "benign message metadata lost from history"
    end
  end

  # ---------------------------------------------------------------------------
  # gRPC attack (8)
  # ---------------------------------------------------------------------------

  describe "gRPC venue access" do
    setup :grpc_venue

    test "8a unauthenticated gRPC access with the interceptor configured is UNAUTHENTICATED(16)",
         %{channel: channel} do
      assert {:error, %GRPC.RPCError{status: 16} = error} =
               Lf.A2a.V1.A2AService.Stub.send_message(channel, grpc_request())

      assert error.message == ~s({"error":"Unauthorized"})
    end

    test "8b garbage credentials are UNAUTHENTICATED(16)", %{channel: channel} do
      assert {:error, %GRPC.RPCError{status: 16}} =
               Lf.A2a.V1.A2AService.Stub.send_message(
                 channel,
                 grpc_request(),
                 metadata: %{"authorization" => "Bearer not-a-jwt"}
               )
    end

    test "8c positive control: an honest attendee on the same gRPC wire is served",
         %{channel: channel} do
      assert {:ok, %Pb.SendMessageResponse{payload: {:task, %Pb.Task{} = task}}} =
               Lf.A2a.V1.A2AService.Stub.send_message(
                 channel,
                 grpc_request(),
                 metadata: %{"authorization" => "Bearer " <> grpc_token("honest-attendee")}
               )

      assert task.status.state == :TASK_STATE_COMPLETED
      assert task.id != ""
    end
  end

  # ---------------------------------------------------------------------------
  # Shared wiring
  # ---------------------------------------------------------------------------

  defp wrapper_transport(_ctx) do
    uniq = System.unique_integer([:positive])
    agent = :"red_team_agent_#{uniq}"
    transport = :"red_team_transport_#{uniq}"

    start_supervised!({Agent, name: agent})
    transport_pid =
      start_supervised!(
        {AshA2A.A2ATransport,
         name: transport, push: [allow_http: true, allow_cidrs: ["127.0.0.1/32"], max_attempts: 1]}
      )

    hook = EphemeralHttp.start!({Receiver, %{test: self()}})

    %{
      agent: agent,
      agent_pid: Process.whereis(agent),
      transport: transport,
      transport_pid: Process.whereis(transport),
      hook: hook.base_url <> "/hook",
      auth:
        AshA2A.Protocol.Plug.Auth.init(
          schemes: %{"bearer" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}},
          verify: &__MODULE__.verify/3
        ),
      plug:
        TransportPlug.init(
          agent: agent,
          base_url: "http://x/a2a",
          transport: transport,
          push_notifications: true
        )
    }
  end

  def verify("bearer", token, _conn), do: {:ok, %{sub: token, token: "raw-credential-of-" <> token}}

  # Real chain: bearer auth middleware -> wrapper transport plug (Plug.Test
  # adapter, same shape the owner-scope court uses).
  defp plug_call(ctx, user, method, params) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => method,
        "params" => params
      })

    conn =
      Plug.Test.conn(:post, "/", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> user)
      |> AshA2A.Protocol.Plug.Auth.call(ctx.auth)
      |> TransportPlug.call(ctx.plug)

    conn
  end

  defp rpc(ctx, user, method, params) do
    conn = plug_call(ctx, user, method, params)
    Jason.decode!(conn.resp_body)
  end

  defp skill_message(skill, extra_metadata \\ %{}) do
    msg =
      struct(Message.new_user([Part.Text.new("go")]),
        metadata: Map.merge(%{"skill" => skill}, extra_metadata)
      )

    {:ok, encoded} = AshA2A.Protocol.JSON.encode(msg)
    encoded
  end

  defp message(extra \\ %{}) do
    Map.merge(skill_message("converse"), extra)
  end

  defp send_task(ctx, user, params) do
    assert %{"result" => result} = rpc(ctx, user, "message/send", params)
    get_in(result, ["task"]) || result
  end

  defp create_task(ctx, user) do
    send_task(ctx, user, %{"message" => message()})
  end

  defp assert_task_not_found(response, label) do
    assert %{
             "error" => %{
               "code" => -32_001,
               "data" => [%{"domain" => "a2a-protocol.org", "reason" => "TASK_NOT_FOUND"}]
             }
           } = response,
           "#{label} did not answer -32001 TASK_NOT_FOUND (got: #{inspect(response)})"
  end

  defp assert_no_internal_keys(%{} = term, path) do
    Enum.each(term, fn
      {"metadata", value} when is_map(value) ->
        Enum.each(value, fn {k, _v} ->
          refute k in @metadata_internal_keys,
                 "internal metadata key #{inspect(k)} leaked at #{path}.metadata"
        end)

        assert_no_internal_keys(value, path <> ".metadata")

      {key, value} when is_binary(key) ->
        refute key in @internal_keys, "internal key #{inspect(key)} leaked at #{path}"

        assert_no_internal_keys(value, path <> "." <> key)

      {_key, value} ->
        assert_no_internal_keys(value, path)
    end)
  end

  defp assert_no_internal_keys(term, path) when is_list(term) do
    term
    |> Enum.with_index()
    |> Enum.each(fn {v, i} -> assert_no_internal_keys(v, "#{path}[#{i}]") end)
  end

  defp assert_no_internal_keys(_scalar, _path), do: :ok

  # -- venue wire helper -------------------------------------------------------

  defp venue_get(base_url, path, headers) do
    conn = Plug.Test.conn(:get, "/" <> Enum.join(path, "/"), nil)

    conn = Enum.reduce(headers, conn, fn {k, v}, acc -> Plug.Conn.put_req_header(acc, k, v) end)

    Venue.call(conn, %{discovery_url: base_url})
  end

  # -- gRPC wiring -------------------------------------------------------------

  defp grpc_venue(_ctx) do
    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [
        AshA2A.Test.Fixture.EchoAgent
      ])

    transport = Module.concat(__MODULE__, Transport)
    start_supervised!({AshA2A.A2ATransport, name: transport})

    Application.put_env(:ash_a2a, AshA2A.Transport.GRPC.Server,
      handler: AshA2A.ConferenceSim.RedTeam.GRPCHandler,
      ctx: %{agent: AshA2A.Test.Fixture.EchoAgent, opts: [], transport: transport}
    )

    auth_opts =
      AshA2A.Protocol.Plug.Auth.init(
        schemes: %{"bearer_auth" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}},
        verify: &GRPCVerify.verify/3
      )

    Application.put_env(:ash_a2a, AshA2A.Transport.GRPC.Server.Endpoint,
      auth: {AshA2A.Transport.GRPC.Auth, auth_opts}
    )

    on_exit(fn ->
      Application.delete_env(:ash_a2a, AshA2A.Transport.GRPC.Server)
      Application.delete_env(:ash_a2a, AshA2A.Transport.GRPC.Server.Endpoint)
    end)

    {:ok, _client_sup} =
      DynamicSupervisor.start_link(strategy: :one_for_one, name: Module.concat(__MODULE__, ClientSup))

    {:ok, _pid, port} = GRPC.Server.start_endpoint(AshA2A.Transport.GRPC.Server.Endpoint, 0)

    on_exit(fn ->
      try do
        GRPC.Server.stop_endpoint(AshA2A.Transport.GRPC.Server.Endpoint)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, channel} = GRPC.Stub.connect("localhost:#{port}", adapter: GRPC.Client.Adapters.Mint)

    %{channel: channel}
  end

  defp grpc_request do
    %Pb.SendMessageRequest{
      message: %Pb.Message{
        message_id: AshA2A.Protocol.ID.generate("red-team"),
        role: :ROLE_USER,
        parts: [%Pb.Part{content: {:text, "red team probe"}}]
      }
    }
  end

  defp grpc_token(sub) do
    b64 = fn bin -> Base.url_encode64(bin, padding: false) end
    secret = GRPCVerify.secret()

    header = b64.(Jason.encode!(%{"alg" => "HS256", "typ" => "JWT"}))
    payload = b64.(Jason.encode!(%{"sub" => sub, "iss" => "red-team-court"}))

    signing_input = header <> "." <> payload
    signature = :crypto.mac(:hmac, :sha256, secret, signing_input)

    signing_input <> "." <> b64.(signature)
  end
end
