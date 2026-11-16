# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT

# ==============================================================================
# Consolidated Test Suite: Root Auth Email Generation
# Target File 1 of Worker 05
# Consolidated from 22 source files:
#   - test/auth_oidc_apikey_surface_test.exs
#   - test/auth_security_hardening_test.exs
#   - test/binding_metrics_test.exs
#   - test/build_capability_index_after_test.exs
#   - test/build_capability_index_mid_list_error_test.exs
#   - test/capability_release_standing_integration_test.exs
#   - test/capability_release_test.exs
#   - test/card_dsl_v1_1_fields_test.exs
#   - test/castle_capability_intake_runtime_test.exs
#   - test/castle_capability_intake_test.exs
#   - test/client_gap_closures_test.exs
#   - test/client_generation_support_test.exs
#   - test/client_live_transport_test.exs
#   - test/docs_nav_coverage_test.exs
#   - test/downgrade_test.exs
#   - test/dsl_card_surface_test.exs
#   - test/dsl_mapping_card_test.exs
#   - test/dsl_verifiers_v1_1_test.exs
#   - test/email_brief_test.exs
#   - test/email_inbound_test.exs
#   - test/email_kernel_entry_test.exs
#   - test/email_plug_test.exs
# ==============================================================================

# --- SECTION 1: Original test/auth_oidc_apikey_surface_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.AuthOidcApiKeySurface.IdpPlug do
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

defmodule AshA2A.AuthOidcApiKeySurface.LiveAgent do
  @moduledoc false
  use AshA2A.Protocol.Agent,
    name: "y8_live",
    description: "y8 uplink fixture",
    capabilities: %{streaming: true}

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _context),
    do: {:input_required, [AshA2A.Protocol.Part.Text.new("more?")]}
end

defmodule AshA2A.AuthOidcApiKeySurfaceTest do
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
        plug: {AshA2A.AuthOidcApiKeySurface.IdpPlug, agent},
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

      start_supervised!(%{
        id: name,
        start: {AshA2A.AuthOidcApiKeySurface.LiveAgent, :start_link, [[name: name]]}
      })

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

# --- SECTION 2: Original test/auth_security_hardening_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.AuthSecurityHardeningTest do
  @moduledoc """
  W5: declared-scope enforcement, digest/unknown scheme refusal, mTLS peer
  certificate extraction, card_security/1 and card-vs-config preflight.
  Real Plug.Test conns through the real Auth plug and real SecurityValidators.
  """

  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias AshA2A.Authority.SecurityPreflight
  alias AshA2A.Protocol.Plug.Auth
  alias AshA2A.Protocol.Plug.SecurityValidators
  alias AshA2A.Protocol.SecurityScheme.{HTTPAuth, MutualTLS}

  @secret "w5-secret-w5-secret-w5-secret-32"

  defp b64(s), do: Base.url_encode64(s, padding: false)

  defp jwt(claims) do
    h = b64(Jason.encode!(%{"alg" => "HS256", "typ" => "JWT"}))
    # `sub` is a default required claim of the bearer validator.
    p = b64(Jason.encode!(Map.put_new(claims, "sub", "w5-user")))
    sig = :crypto.mac(:hmac, :sha256, @secret, "#{h}.#{p}") |> b64()
    "#{h}.#{p}.#{sig}"
  end

  defp exp, do: System.system_time(:second) + 600

  defp scoped_auth(config_extra \\ []) do
    Auth.init(
      schemes: %{"bearer" => %HTTPAuth{scheme: "bearer", bearer_format: "JWT"}},
      security: [%{"bearer" => ["notes.read"]}],
      verify: SecurityValidators.verifier(%{"bearer" => [secret: @secret] ++ config_extra})
    )
  end

  defp call_bearer(token, opts) do
    conn(:post, "/")
    |> put_req_header("authorization", "Bearer " <> token)
    |> Auth.call(opts)
  end

  describe "declared scope enforcement" do
    test "token with the declared scope is admitted" do
      conn = call_bearer(jwt(%{"exp" => exp(), "scope" => "notes.read other"}), scoped_auth())
      refute conn.halted
      assert %{scheme: "bearer"} = Auth.get_identity(conn)
    end

    test "token missing the declared scope gets 403 insufficient_scope" do
      conn = call_bearer(jwt(%{"exp" => exp(), "scope" => "other"}), scoped_auth())
      assert conn.halted
      assert conn.status == 403
      [challenge | _] = get_resp_header(conn, "www-authenticate")
      assert challenge =~ ~s(error="insufficient_scope")
      assert challenge =~ "notes.read"
    end

    test "explicit config required_scopes wins over declared scopes" do
      opts = scoped_auth(required_scopes: ["other"])
      conn = call_bearer(jwt(%{"exp" => exp(), "scope" => "other"}), opts)
      refute conn.halted
    end

    test "garbage token is still a plain 401" do
      conn = call_bearer("a.b.c", scoped_auth())
      assert conn.status == 401
    end
  end

  describe "HTTPAuth scheme handling" do
    test "digest is unsupported, never read as bearer" do
      opts =
        Auth.init(
          schemes: %{"d" => %HTTPAuth{scheme: "digest"}},
          verify: fn _, _, _ -> {:ok, %{id: "x"}} end
        )

      conn =
        conn(:post, "/")
        |> put_req_header("authorization", "Digest username=\"a\"")
        |> Auth.call(opts)

      assert conn.status == 401

      bearer_conn =
        conn(:post, "/")
        |> put_req_header("authorization", "Bearer tok")
        |> Auth.call(opts)

      assert bearer_conn.status == 401
    end

    test "basic challenge is capitalised" do
      opts =
        Auth.init(
          schemes: %{"b" => %HTTPAuth{scheme: "BASIC"}},
          verify: fn _, _, _ -> {:error, "no"} end
        )

      conn = conn(:post, "/") |> Auth.call(opts)
      assert conn.status == 401
      assert ["Basic realm=\"a2a\""] = get_resp_header(conn, "www-authenticate")
    end

    test "bearer_format JWT rejects a non-JWT token" do
      conn = call_bearer("opaque-token", scoped_auth())
      assert conn.status == 401
    end
  end

  describe "mTLS" do
    @der <<48, 3, 2, 1, 1>>

    defp fingerprint(der), do: Base.encode16(:crypto.hash(:sha256, der), case: :lower)

    defp mtls_opts(config, extra \\ []) do
      Auth.init(
        [
          schemes: %{"mtls" => %MutualTLS{}},
          verify: SecurityValidators.verifier(%{"mtls" => [kind: :mtls] ++ config})
        ] ++ extra
      )
    end

    test "peer certificate with an allowed fingerprint is admitted" do
      conn =
        conn(:post, "/")
        |> put_peer_data(%{address: {127, 0, 0, 1}, port: 1, ssl_cert: @der})
        |> Auth.call(mtls_opts(fingerprints: [fingerprint(@der)]))

      refute conn.halted
      assert %{identity: %{fingerprint: fp}} = Auth.get_identity(conn)
      assert fp == fingerprint(@der)
    end

    test "peer certificate not in the allowlist is refused" do
      conn =
        conn(:post, "/")
        |> put_peer_data(%{address: {127, 0, 0, 1}, port: 1, ssl_cert: @der})
        |> Auth.call(mtls_opts(fingerprints: [String.duplicate("0", 64)]))

      assert conn.status == 401
    end

    test "no allowlist configured refuses fail-closed" do
      conn =
        conn(:post, "/")
        |> put_peer_data(%{address: {127, 0, 0, 1}, port: 1, ssl_cert: @der})
        |> Auth.call(mtls_opts([]))

      assert conn.status == 401
    end

    test "no certificate and no header is unsupported (401)" do
      conn = conn(:post, "/") |> Auth.call(mtls_opts(fingerprints: [fingerprint(@der)]))
      assert conn.status == 401
    end

    test "forwarded fingerprint header is ignored unless :mtls_header is set" do
      base = conn(:post, "/") |> put_req_header("x-client-cert", fingerprint(@der))
      off = Auth.call(base, mtls_opts(fingerprints: [fingerprint(@der)]))
      assert off.status == 401

      on =
        Auth.call(
          base,
          mtls_opts([fingerprints: [fingerprint(@der)]], mtls_header: "x-client-cert")
        )

      refute on.halted
    end
  end

  describe "card consistency" do
    test "card_security/1 mirrors the plug options" do
      opts = [
        schemes: %{"bearer" => %HTTPAuth{scheme: "bearer"}},
        security: [%{"bearer" => ["a"]}],
        verify: fn _, _, _ -> {:error, "x"} end
      ]

      assert {%{"bearer" => %HTTPAuth{}}, [%{"bearer" => ["a"]}]} = Auth.card_security(opts)
    end

    test "preflight accepts consistent and flags dangling scheme references" do
      ok = %{
        security_schemes: %{"bearer" => %HTTPAuth{scheme: "bearer"}},
        security: [%{"bearer" => []}],
        skills: [%{security_requirements: [%{"bearer" => []}]}]
      }

      assert :ok = SecurityPreflight.check_card_security(ok)

      bad = %{ok | skills: [%{security_requirements: [%{"ghost" => []}]}]}

      assert {:error, [%{code: :card_security_unknown_scheme}]} =
               SecurityPreflight.check_card_security(bad)
    end
  end
end

# --- SECTION 3: Original test/binding_metrics_test.exs ---
defmodule AshA2A.BindingMetricsTest do
  use ExUnit.Case, async: false

  alias AshA2A.Protocol.Telemetry, as: T
  alias AshA2A.Telemetry.Metrics

  test "definitions carry a binding tag for request count, duration and errors" do
    reqs =
      Enum.filter(
        Metrics.definitions(),
        &(&1.event |> Enum.take(3) == [:ash_a2a, :transport, :request])
      )

    assert length(reqs) == 3
    assert Enum.all?(reqs, &(:binding in &1.tags))
  end

  test "request_span emits stop with binding and error event on failure" do
    ref = make_ref()
    me = self()
    id = "w15-#{inspect(ref)}"

    :telemetry.attach_many(
      id,
      [[:ash_a2a, :transport, :request, :stop], [:ash_a2a, :transport, :request, :error]],
      fn ev, m, meta, _ -> send(me, {ref, ev, m, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)

    for b <- [:jsonrpc, :http_json, :grpc] do
      assert :done = T.request_span(b, fn -> {:done, false} end)
      assert_receive {^ref, [:ash_a2a, :transport, :request, :error], %{count: 1}, %{binding: ^b}}

      assert_receive {^ref, [:ash_a2a, :transport, :request, :stop], %{duration: _},
                      %{binding: ^b}}
    end
  end
end

# --- SECTION 4: Original test/build_capability_index_after_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.BuildCapabilityIndexAfterTest do
  @moduledoc """
  Chicago-style test (real module, real function call, no mocks) for the
  Zach-Daniel review finding on
  `AshA2A.Transformers.BuildCapabilityIndex.after?/1`: it must not claim a
  blanket "run after every other transformer" ordering, since it has no
  actual data dependency on any other transformer's output.
  """
  use ExUnit.Case, async: true

  alias AshA2A.Transformers.BuildCapabilityIndex

  test "after?/1 does not claim a blanket ordering dependency on unrelated transformers" do
    refute BuildCapabilityIndex.after?(Ash.Resource.Transformers.CachePrimaryKey)
    refute BuildCapabilityIndex.after?(SomeUnrelatedExtension.Transformers.Whatever)
  end
end

# --- SECTION 5: Original test/build_capability_index_mid_list_error_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.BuildCapabilityIndexMidListErrorTest do
  @moduledoc """
  Chicago-style, standalone from `test/ash_a2a_test.exs`: real repro for the
  reviewed `Enum.reduce`-accumulator finding in
  `AshA2A.Transformers.BuildCapabilityIndex.transform/1`
  (lib/ash_a2a/transformers/build_capability_index.ex). A domain-level `a2a`
  block declaring 2+ skills where an earlier one fails `resolve_resource/4`
  used to leave `{:error, %Spark.Error.DslError{}}` as the reduce
  accumulator, then crash with a raw `FunctionClauseError` on the next
  entity instead of short-circuiting -- because the reducer's only clause
  matched `{:ok, dsl, skills}`. This compiles a real, standalone `Ash.Domain`
  with two domain-level skills -- the first missing `resource` (malformed),
  the second well-formed -- through the genuine `BuildCapabilityIndex`
  transformer. No Mock/mox/patch, no hand-built refusal:
  `Spark.Test.assert_dsl_error/2` is Spark's own real collector for the
  `Spark.Error.DslError` a domain's `@after_verify` would otherwise only
  emit as a stderr warning.
  """

  use ExUnit.Case

  test "a non-last malformed skill yields a clean DslError, not a FunctionClauseError" do
    # Transformer errors (unlike `AshA2A.Verify`'s `@after_verify` errors,
    # covered by `Spark.Test.assert_dsl_error/2` elsewhere in this suite) are
    # raised synchronously from `Spark.Dsl.__before_compile__/1` -- so the
    # real assertion here is `assert_raise`, not the after_verify message
    # collector. This is the load-bearing check: before the fix, this same
    # `defmodule` raised `FunctionClauseError` instead (the reduce
    # accumulator's `{:error, _}` shape did not match the reducer's
    # `{:ok, dsl, skills}`-only clause on the next iteration).
    error =
      assert_raise Spark.Error.DslError, fn ->
        defmodule Elixir.AshA2A.Test.Fixture.MidListResolutionFailure do
          use Ash.Domain, extensions: [AshA2A]

          resources do
            resource(AshA2A.Test.Fixture.Echo)
          end

          a2a do
            skill(:first_bad, :read)
            skill(:second_good, AshA2A.Test.Fixture.Echo, :read)
          end
        end
      end

    assert error.message =~ "domain-level skill overrides must declare a resource"
  end
end

# --- SECTION 6: Original test/capability_release_standing_integration_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.CapabilityReleaseStandingIntegrationTest do
  use ExUnit.Case, async: false
  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, CapabilityRelease, Command, CommandBus, Identity}
  alias AshA2A.Chicago.{Result, StandingReceipt, Subject}
  alias AshA2A.Chicago.Courts.ObserverQualification
  alias AshA2A.Test.ActuatorCounter
  alias AshA2A.Test.Fixture.AuthorityProbe

  @moduletag :tmp_dir
  @capability "AshA2A.Test.Fixture.AuthorityProbe.actuate"

  defp digest(c), do: "sha256:" <> String.duplicate(c, 64)

  defmodule MutatingStore do
    @behaviour AshA2A.ReceiptStore

    alias AshA2A.ReceiptStore.Memory

    def claim(command, opts), do: Memory.claim(command, opts)
    def commit(receipt, opts), do: Memory.commit(receipt, opts)
    def fetch(command_id, opts), do: Memory.fetch(command_id, opts)

    def claim_actuation(actuation, command, opts),
      do: Memory.claim_actuation(actuation, command, opts)

    def commit_actuation(actuation, receipt, opts),
      do: Memory.commit_actuation(actuation, receipt, opts)

    def release_actuation(actuation, opts), do: Memory.release_actuation(actuation, opts)

    def confirm_claim(command_id, execution_id, opts) do
      File.write!(
        Keyword.fetch!(opts, :mutate_receipt_path),
        Keyword.fetch!(opts, :mutated_receipt)
      )

      Memory.confirm_claim(command_id, execution_id, opts)
    end
  end

  test "real durable exact-subject receipt is required", %{tmp_dir: dir} do
    repo = init_repo!(dir)
    sha = commit!(repo, "app.txt", "v1")
    receipt = receipt!(repo)

    path =
      Path.join([
        repo,
        AshA2A.StandingRef.receipt_dir("sa2a", sha),
        AshA2A.StandingRef.standing_file("sa2a")
      ])

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(receipt))
    git!(repo, ["add", "receipts"])
    git!(repo, ["commit", "-q", "--no-verify", "-m", "receipt"])

    candidate =
      CapabilityRelease.candidate("standing.cap", "26.9.30", digest("a"), subject_revision: sha)

    {:ok, admitted} = CapabilityRelease.admit(candidate, digest("b"))

    assert {:error, {:standing_binding_required, _}} =
             CapabilityRelease.release(admitted, digest("c"))

    assert {:ok, released} =
             CapabilityRelease.release(admitted, repo: repo, standing: "CONFORMANT")

    assert released.standing_binding.subject_revision == sha
    assert released.standing_binding.technical_standing == "CONFORMANT"
    assert released.standing_binding.external_standing == "NONE"
    assert released.standing_binding.runtime_authority == "NONE"
    assert released.release_digest == released.standing_binding.portable_identity
    assert {:ok, closure} = CapabilityRelease.freeze([released], repo: repo)
    assert {:ok, ^released} = CapabilityRelease.select(closure, "standing.cap")
    assert CapabilityRelease.released_ids(closure) == ["standing.cap"]

    assert :ok =
             CapabilityRelease.guard("standing.cap",
               capability_release_closure: closure,
               repo: repo
             )

    assert {:ok, binding} =
             CapabilityRelease.binding("standing.cap",
               capability_release_closure: closure,
               repo: repo
             )

    assert {:ok, [%{id: "standing.cap"}]} =
             CapabilityRelease.filter_skills(
               [%{id: "candidate"}, %{id: "standing.cap"}],
               capability_release_closure: closure,
               repo: repo
             )

    attrs = CapabilityRelease.attributes(binding)
    assert attrs.standing_subject_revision == sha
    assert attrs.external_standing == "NONE"
    assert attrs.runtime_authority == "NONE"

    stale = %{admitted | subject_revision: String.duplicate("f", 40)}

    assert {:error, {:standing_exact_subject_mismatch, _, ^sha}} =
             CapabilityRelease.release(stale, repo: repo, standing: "CONFORMANT")
  end

  test "mutated artifact receipt is refused at strict runtime replay", %{tmp_dir: dir} do
    repo = init_repo!(Path.join(dir, "artifact-case"))
    sha = commit!(repo, "app.txt", "v1")
    receipt = receipt!(repo)
    artifacts = Path.join(dir, "artifacts")
    artifact_dir = Path.join(artifacts, "sa2a-conformance-" <> sha)
    receipt_path = Path.join([artifact_dir, AshA2A.StandingRef.standing_file("sa2a")])
    File.mkdir_p!(Path.dirname(receipt_path))
    File.write!(receipt_path, JSON.encode!(receipt))

    candidate =
      CapabilityRelease.candidate("artifact.cap", "26.9.30", digest("d"), subject_revision: sha)

    {:ok, admitted} = CapabilityRelease.admit(candidate, digest("e"))

    assert {:ok, released} =
             CapabilityRelease.release(admitted,
               repo: repo,
               artifacts_dir: artifacts,
               standing: "CONFORMANT"
             )

    assert String.starts_with?(released.standing_binding.receipt_source, "artifact:")

    assert {:ok, closure} =
             CapabilityRelease.freeze([released], repo: repo, artifacts_dir: artifacts)

    mutated = Map.put(receipt, "claim", "mutated after release")
    File.write!(receipt_path, JSON.encode!(mutated))

    assert {:error, _reason} =
             CapabilityRelease.binding("artifact.cap",
               capability_release_closure: closure,
               repo: repo,
               artifacts_dir: artifacts
             )
  end

  test "pre-DO replay refuses standing mutated after initial binding and preserves non-authority receipt evidence",
       %{tmp_dir: dir} do
    repo = init_repo!(Path.join(dir, "pre-do-case"))
    sha = commit!(repo, "app.txt", "v1")
    receipt = receipt!(repo)
    artifacts = Path.join(dir, "pre-do-artifacts")
    artifact_dir = Path.join(artifacts, "sa2a-conformance-" <> sha)
    receipt_path = Path.join([artifact_dir, AshA2A.StandingRef.standing_file("sa2a")])
    File.mkdir_p!(Path.dirname(receipt_path))
    File.write!(receipt_path, JSON.encode!(receipt))

    candidate =
      CapabilityRelease.candidate(@capability, "26.9.30", digest("8"), subject_revision: sha)

    {:ok, admitted} = CapabilityRelease.admit(candidate, digest("9"))

    assert {:ok, released} =
             CapabilityRelease.release(admitted,
               repo: repo,
               artifacts_dir: artifacts,
               standing: "CONFORMANT"
             )

    assert {:ok, closure} =
             CapabilityRelease.freeze([released], repo: repo, artifacts_dir: artifacts)

    start_supervised!(ActuatorCounter)

    store_name =
      Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")

    start_supervised!({AshA2A.ReceiptStore.Memory, name: store_name})

    prior_outbox = Application.get_env(:ash_a2a, :receipt_outbox_dir)
    outbox = Path.join(dir, "pre-do-outbox")
    Application.put_env(:ash_a2a, :receipt_outbox_dir, outbox)

    on_exit(fn ->
      if prior_outbox do
        Application.put_env(:ash_a2a, :receipt_outbox_dir, prior_outbox)
      else
        Application.delete_env(:ash_a2a, :receipt_outbox_dir)
      end
    end)

    principal = Identity.principal("standing-operator")

    command =
      Command.new(@capability,
        command_id: "standing-pre-do-#{System.unique_integer([:positive])}",
        agent_id: "standing-agent",
        principal_id: principal,
        authority: Authority.new(principal, @capability, token_id: "standing-pre-do-token"),
        input: %{}
      )

    mutated =
      receipt
      |> Map.put("claim", "mutated after initial release binding and before DO")
      |> JSON.encode!()

    assert ActuatorCounter.count() == 0

    assert {:error, %{code: :capability_release_refused, receipt: refusal_receipt}} =
             CommandBus.run(
               command,
               data_message(%{}),
               AuthorityProbe,
               store: MutatingStore,
               store_opts: [
                 name: store_name,
                 mutate_receipt_path: receipt_path,
                 mutated_receipt: mutated
               ],
               capability_release_closure: closure,
               repo: repo,
               artifacts_dir: artifacts
             )

    assert ActuatorCounter.count() == 0

    intended = refusal_receipt.intended_effect
    assert intended.standing_binding_identity == released.standing_binding.portable_identity
    assert intended.standing_subject_revision == sha
    assert intended.standing_receipt_digest == released.standing_binding.receipt_digest
    assert intended.technical_standing == "CONFORMANT"
    assert intended.external_standing == "NONE"
    assert intended.runtime_authority == "NONE"
  end

  defp init_repo!(dir) do
    repo = Path.join(dir, "subject")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.email", "standing@example.invalid"])
    git!(repo, ["config", "user.name", "standing"])
    git!(repo, ["config", "commit.gpgsign", "false"])
    repo
  end

  defp commit!(repo, file, body) do
    File.write!(Path.join(repo, file), body)
    git!(repo, ["add", file])
    git!(repo, ["commit", "-q", "--no-verify", "-m", file])
    git!(repo, ["rev-parse", "HEAD"])
  end

  defp receipt!(repo) do
    fs = ObserverQualification.falsifiers()
    f = Enum.find(fs, &(&1.kind == :negative))

    rs =
      for gate <- 1..3,
          do: %{
            Result.negative(f, attempt_observed?: true, forbidden_outcome_observed?: false)
            | gate: gate,
              ocel_corroborated?: true
          }

    StandingReceipt.build(%{
      profile: :core,
      subject: Subject.capture(repo: repo),
      courts: [ObserverQualification],
      falsifiers: fs,
      results: rs,
      ocel: %{
        sha256: String.duplicate("a", 64),
        bytes: 1,
        events: 1,
        objects: 1,
        mapping_digest: "standing",
        dropped: 0,
        gaps: 0
      },
      ocel_validation: %{status: :valid, validator: "independent", report: %{}},
      run_id: "standing-integration"
    })
  end

  defp git!(repo, args) do
    {out, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    String.trim(out)
  end
end

# --- SECTION 7: Original test/capability_release_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.CapabilityReleaseTest do
  use ExUnit.Case, async: true

  alias AshA2A.{CapabilityRelease, StandingBinding}

  defp digest(char), do: "sha256:" <> String.duplicate(char, 64)

  defp standing_binding(id) do
    fields = %{
      "schema" => "ash-a2a.standing-binding/v1",
      "capability_id" => id,
      "capability_digest" => digest("a"),
      "subject_revision" => String.duplicate("1", 40),
      "court" => "sa2a",
      "technical_standing" => "CONFORMANT",
      "required_standing" => "CONFORMANT",
      "receipt_digest" => digest("c"),
      "receipt_source" => "git:test:receipts/courts/sa2a",
      "external_standing" => "NONE",
      "runtime_authority" => "NONE"
    }

    identity =
      "sha256:" <>
        (:crypto.hash(:sha256, Jcs.encode(fields))
         |> Base.encode16(case: :lower))

    %StandingBinding{
      capability_id: id,
      capability_digest: digest("a"),
      subject_revision: String.duplicate("1", 40),
      court: "sa2a",
      technical_standing: "CONFORMANT",
      required_standing: "CONFORMANT",
      receipt_digest: digest("c"),
      receipt_source: "git:test:receipts/courts/sa2a",
      portable_identity: identity,
      external_standing: "NONE",
      runtime_authority: "NONE"
    }
  end

  defp released(id \\ "cap", version \\ "26.9.30") do
    candidate =
      CapabilityRelease.candidate(id, version, digest("a"),
        subject_revision: String.duplicate("1", 40)
      )

    {:ok, admitted} = CapabilityRelease.admit(candidate, digest("b"))
    binding = standing_binding(id)

    %{
      admitted
      | state: :released,
        release_digest: binding.portable_identity,
        standing_binding: binding
    }
  end

  test "digest-shaped caller input cannot release an admitted capability" do
    candidate = CapabilityRelease.candidate("cap", "1", digest("a"))
    {:ok, admitted} = CapabilityRelease.admit(candidate, digest("b"))

    assert {:error, {:standing_binding_required, _}} =
             CapabilityRelease.release(admitted, digest("c"))

    assert {:error, :capability_exact_subject_missing} =
             CapabilityRelease.release(admitted, standing: "CONFORMANT")
  end

  test "fabricated durable-looking standing cannot manufacture a frozen fleet" do
    assert {:error, :standing_receipt_source_invalid} =
             CapabilityRelease.freeze([released("forged-source")])
  end

  test "freeze refuses release mismatch, forged standing identity, and authority conflation" do
    cap = released("forged")

    release_mismatch = %{cap | release_digest: digest("e")}

    assert {:error, {:standing_release_digest_mismatch, "forged"}} =
             CapabilityRelease.freeze([release_mismatch])

    forged_identity = digest("f")

    forged = %{
      cap
      | release_digest: forged_identity,
        standing_binding: %{cap.standing_binding | portable_identity: forged_identity}
    }

    assert {:error, {:standing_binding_identity_mismatch, _, ^forged_identity}} =
             CapabilityRelease.freeze([forged])

    binding = standing_binding("authority")
    conflated_binding = %{binding | runtime_authority: "ALLOW"}

    payload = %{
      "schema" => "ash-a2a.standing-binding/v1",
      "capability_id" => conflated_binding.capability_id,
      "capability_digest" => conflated_binding.capability_digest,
      "subject_revision" => conflated_binding.subject_revision,
      "court" => conflated_binding.court,
      "technical_standing" => conflated_binding.technical_standing,
      "required_standing" => conflated_binding.required_standing,
      "receipt_digest" => conflated_binding.receipt_digest,
      "receipt_source" => conflated_binding.receipt_source,
      "external_standing" => conflated_binding.external_standing,
      "runtime_authority" => conflated_binding.runtime_authority
    }

    forged_identity =
      "sha256:" <>
        (:crypto.hash(:sha256, Jcs.encode(payload))
         |> Base.encode16(case: :lower))

    conflated_binding = %{conflated_binding | portable_identity: forged_identity}

    cap = %{
      released("authority")
      | standing_binding: conflated_binding,
        release_digest: forged_identity
    }

    assert {:error, :runtime_authority_conflated} = CapabilityRelease.freeze([cap])
  end

  test "portable closure identity is independent of input ordering" do
    a = released("a")
    b = released("b")

    first = CapabilityRelease.portable_digest([a, b])
    second = CapabilityRelease.portable_digest([b, a])

    assert first == second
    assert String.starts_with?(first, "sha256:")
  end

  test "strict mode without closure fails closed while legacy stays compatible" do
    assert {:error, :capability_release_closure_missing} =
             CapabilityRelease.guard("capability", capability_release_mode: :strict)

    assert :ok =
             CapabilityRelease.guard("capability", capability_release_mode: :legacy)
  end

  test "retired capability cannot freeze back into executable closure" do
    capability = released("cap")
    {:ok, retired} = CapabilityRelease.retire(capability, digest("d"))

    assert {:error, {:not_released, "cap", :retired}} =
             CapabilityRelease.freeze([retired])
  end

  test "duplicate capability id is refused before evidence replay" do
    assert {:error, {:duplicate_capability_id, "cap"}} =
             CapabilityRelease.freeze([
               released("cap", "1"),
               released("cap", "2")
             ])
  end

  test "legacy skill filtering preserves existing capability index" do
    skills = [%{id: "a"}, %{id: "b"}]

    assert {:ok, ^skills} =
             CapabilityRelease.filter_skills(skills,
               capability_release_mode: :legacy
             )
  end

  test "strict filtering without closure refuses instead of advertising candidates" do
    assert {:error, :capability_release_closure_missing} =
             CapabilityRelease.filter_skills([%{id: "candidate"}],
               capability_release_mode: :strict
             )
  end
end

# --- SECTION 8: Original test/card_dsl_v1_1_fields_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.CardDslV11FieldsTest.Resource do
  @moduledoc false
  use Ash.Resource,
    domain: AshA2A.CardDslV11FieldsTest.HomeDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])
  end

  a2a do
    skill(:echo, :read)
  end
end

defmodule AshA2A.CardDslV11FieldsTest.HomeDomain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.CardDslV11FieldsTest.Resource)
  end
end

defmodule AshA2A.CardDslV11FieldsTest.Agent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.CardDslV11FieldsTest.Resource,
    name: "y6_card_dsl_agent",
    public_skills: [:echo]
end

defmodule AshA2A.CardDslV11FieldsTest.OAuthDomain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A, AshA2A.Domain], validate_config_inclusion?: false

  resources do
    resource(AshA2A.CardDslV11FieldsTest.Resource)
  end

  agent do
    name "y6-card-dsl"
    description "Y6 DSL-declared v1.1 card surface"
  end

  security do
    security_scheme(:oauth, :oauth2,
      oauth_flows: %{
        "deviceCode" => %{
          "deviceAuthorizationUrl" => "https://auth.example.com/device",
          "tokenUrl" => "https://auth.example.com/token",
          "scopes" => %{"read" => "Read access"}
        }
      }
    )

    security_scheme(:oauth_pkce, :oauth2,
      oauth_flows: %{
        "authorizationCode" => %{
          "authorizationUrl" => "https://auth.example.com/authorize",
          "tokenUrl" => "https://auth.example.com/token",
          "scopes" => %{"read" => "Read access"},
          "pkceRequired" => true
        }
      }
    )

    requirements ["oauth"]
  end

  transport do
    base_url "https://y6.example.com"

    extension("https://example.com/ext/y6/v1",
      description: "Y6 extension",
      required: true,
      params: %{"mode" => "strict"}
    )

    mount agent: AshA2A.CardDslV11FieldsTest.Agent,
          path: "/rpc",
          binding: :jsonrpc

    mount agent: AshA2A.CardDslV11FieldsTest.Agent,
          path: "/rest",
          binding: :rest,
          tenant: "tenant-y6",
          protocol_version: "1.1"
  end
end

defmodule AshA2A.CardDslV11FieldsTest do
  use ExUnit.Case, async: true

  alias AshA2A.Protocol.CardSigning
  alias AshA2A.Protocol.JSON, as: Codec

  @key "y6-shared-secret-0123456789abcdef0"

  defp card, do: AshA2A.Info.agent_card(AshA2A.CardDslV11FieldsTest.OAuthDomain)
  defp wire(card), do: Codec.encode_agent_card(card, url: card.url)

  test "mount binding :rest maps to protocolBinding HTTP+JSON" do
    assert AshA2A.Domain.Mount.protocol_binding(:rest) == "HTTP+JSON"
    assert AshA2A.Domain.Mount.protocol_binding(:jsonrpc) == "JSONRPC"

    bindings = Enum.map(card().supported_interfaces, & &1.protocol_binding)
    assert bindings == ["JSONRPC", "HTTP+JSON"]
  end

  test "interface tenant and protocolVersion are emitted and decoded" do
    rest =
      wire(card())["supportedInterfaces"] |> Enum.find(&(&1["protocolBinding"] == "HTTP+JSON"))

    assert rest["tenant"] == "tenant-y6"
    assert rest["protocolVersion"] == "1.1"

    {:ok, decoded} = Codec.decode_agent_card(wire(card()))
    rest = Enum.find(decoded.supported_interfaces, &(&1.protocol_binding == "HTTP+JSON"))
    assert rest.tenant == "tenant-y6"
    assert rest.protocol_version == "1.1"
  end

  test "DSL extension and deviceCode+pkce flows survive build, encode and decode" do
    wire = wire(card())

    assert [%{"uri" => "https://example.com/ext/y6/v1", "required" => true} = ext] =
             wire["capabilities"]["extensions"]

    assert ext["params"] == %{"mode" => "strict"}

    schemes = wire["securitySchemes"]

    assert get_in(schemes, [
             "oauth",
             "oauth2SecurityScheme",
             "flows",
             "deviceCode",
             "deviceAuthorizationUrl"
           ]) ==
             "https://auth.example.com/device"

    assert get_in(schemes, [
             "oauth_pkce",
             "oauth2SecurityScheme",
             "flows",
             "authorizationCode",
             "pkceRequired"
           ]) ==
             true

    assert {:ok, decoded} = Codec.decode_agent_card(wire)

    assert [%{uri: "https://example.com/ext/y6/v1", required: true}] =
             decoded.capabilities.extensions

    assert Map.has_key?(decoded.security_schemes, "oauth")
    assert Map.has_key?(decoded.security_schemes, "oauth_pkce")
  end

  test "signed card carries the declared extension, flows, tenant and version" do
    signed = CardSigning.sign(card(), @key, kid: "y6-k1")
    wire = wire(signed)

    assert [%{"protected" => _, "signature" => _}] = wire["signatures"]
    assert CardSigning.verify(wire, @key) == :ok
    assert [%{"uri" => "https://example.com/ext/y6/v1"}] = wire["capabilities"]["extensions"]

    assert get_in(wire, [
             "securitySchemes",
             "oauth",
             "oauth2SecurityScheme",
             "flows",
             "deviceCode"
           ])

    assert Enum.any?(wire["supportedInterfaces"], &(&1["tenant"] == "tenant-y6"))

    tampered = put_in(wire, ["capabilities", "extensions"], [])
    assert {:error, _} = CardSigning.verify(tampered, @key)
  end

  test "closed protocolBinding set rejects an unknown binding on decode" do
    wire = wire(card())

    bad =
      update_in(wire["supportedInterfaces"], fn [first | rest] ->
        [Map.put(first, "protocolBinding", "CARRIER-PIGEON") | rest]
      end)

    assert {:error, {:invalid_field, "supportedInterfaces.protocolBinding"}} =
             Codec.decode_agent_card(bad)
  end

  describe "oauth_flows validation" do
    test "validate_oauth_flows accepts deviceCode and pkceRequired" do
      assert {:ok, _} =
               AshA2A.Domain.validate_oauth_flows(%{
                 "deviceCode" => %{
                   "deviceAuthorizationUrl" => "https://a/d",
                   "tokenUrl" => "https://a/t",
                   "scopes" => %{}
                 }
               })

      assert {:ok, _} =
               AshA2A.Domain.validate_oauth_flows(%{
                 "authorizationCode" => %{
                   "authorizationUrl" => "https://a/a",
                   "tokenUrl" => "https://a/t",
                   "scopes" => %{},
                   "pkceRequired" => true
                 }
               })
    end

    test "bad shapes are refused" do
      assert {:error, _} = AshA2A.Domain.validate_oauth_flows(%{"bogus" => %{}})
      assert {:error, _} = AshA2A.Domain.validate_oauth_flows(%{})
      assert {:error, _} = AshA2A.Domain.validate_oauth_flows("nope")
      # deviceCode missing REQUIRED members
      assert {:error, _} =
               AshA2A.Domain.validate_oauth_flows(%{
                 "deviceCode" => %{"tokenUrl" => "https://a/t"}
               })
    end

    test "a domain declaring a bad flow fails at compile time" do
      assert_raise Spark.Error.DslError, fn ->
        Code.compile_string("""
        defmodule AshA2A.CardDslV11FieldsTest.BadFlowDomain do
          use Ash.Domain, extensions: [AshA2A.Domain]

          security do
            security_scheme :oauth, :oauth2,
              oauth_flows: %{"deviceCode" => %{"tokenUrl" => "https://a/t"}}
          end
        end
        """)
      end
    end
  end
end

# --- SECTION 9: Original test/castle_capability_intake_runtime_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.CastleCapabilityIntakeRuntimeTest do
  use ExUnit.Case, async: true

  alias AshA2A.CastleCapabilityIntake

  test "adapter and protocol donors terminate at transport without authority" do
    assert CastleCapabilityIntake.owner_capability() == "SA2A_TRANSPORT"
    assert CastleCapabilityIntake.authority_ceiling() == :construct
    assert length(CastleCapabilityIntake.donors()) == 3

    assert {:ok, donor} = CastleCapabilityIntake.fetch("seanchatmangpt/ash_atlassian")
    assert donor.sha == "43e3d21b7c4e4571493fcf3757392ed16f2dd967"
    refute CastleCapabilityIntake.transport_authority?(donor)

    assert {:error, :unknown_castle_edge_donor} =
             CastleCapabilityIntake.fetch("seanchatmangpt/unknown")
  end
end

# --- SECTION 10: Original test/castle_capability_intake_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.CastleCapabilityIntakeTest do
  use ExUnit.Case, async: true

  @path Path.expand("../semantic/castle-capability-intake.ttl", __DIR__)

  test "external adapters and protocol knowledge terminate at the SA2A transport owner" do
    graph = File.read!(@path)

    assert graph =~ "50fdfa20c84205a80c6eb94e916cffbedc4b816e"
    assert graph =~ ~s(eco:ownerCapability "SA2A_TRANSPORT")
    assert length(Regex.scan(~r/a eco:ProjectedCapability/, graph)) == 3

    for repo <- [
          "seanchatmangpt/ash_atlassian",
          "seanchatmangpt/ash_planning_center",
          "seanchatmangpt/agile-protocol-specification"
        ] do
      assert graph =~ ~s(eco:sourceRepository "#{repo}")
    end

    assert graph =~ ~s(eco:projectionStanding "CANDIDATE")
    assert graph =~ ~s(eco:authorityCeiling "CONSTRUCT")
    refute graph =~ ~s(eco:authorityCeiling "DO")
    refute graph =~ ~s(eco:runtimePlacement "RUNTIME_CORE")
    refute graph =~ ~s(eco:runtimePlacement "CONSEQUENCE_CROWN")
  end
end

# --- SECTION 11: Original test/client_gap_closures_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ClientGapClosures.Recorder do
  @moduledoc false
  # Real Plug served by a real Bandit listener (no mocks): records every request
  # to the test process and answers per `mode`.
  @behaviour Plug
  import Plug.Conn

  @error_info "type.googleapis.com/google.rpc.ErrorInfo"

  @task_working %{
    "id" => "t1",
    "contextId" => "c1",
    "status" => %{"state" => "TASK_STATE_WORKING"}
  }
  @task_done %{
    "id" => "t1",
    "contextId" => "c1",
    "status" => %{"state" => "TASK_STATE_COMPLETED"}
  }
  @card %{
    "name" => "w7",
    "description" => "d",
    "url" => "http://127.0.0.1/w7",
    "version" => "1.0.0",
    "skills" => [],
    "supportedInterfaces" => [],
    "capabilities" => %{},
    "defaultInputModes" => ["text/plain"],
    "defaultOutputModes" => ["text/plain"]
  }

  def init(opts), do: opts

  def call(conn, %{test: test, mode: mode} = opts) do
    {:ok, body, conn} = read_body(conn)

    send(
      test,
      {:req, conn.method, conn.request_path, conn.query_string, Map.new(conn.req_headers), body}
    )

    respond(mode, conn, body, opts)
  end

  defp json(conn, status, map) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(map))
  end

  defp respond(:unauthorized, conn, _body, _opts) do
    conn
    |> put_resp_header("www-authenticate", ~s(Bearer realm="a2a", error="invalid_token"))
    |> json(401, %{"error" => "Unauthorized"})
  end

  defp respond(:forbidden, conn, _body, _opts), do: json(conn, 403, %{"error" => "nope"})

  defp respond(:task_not_found, conn, _body, _opts) do
    json(conn, 404, %{
      "error" => %{
        "code" => 404,
        "status" => "NOT_FOUND",
        "message" => "no such task",
        "details" => [
          %{"@type" => @error_info, "reason" => "TASK_NOT_FOUND", "domain" => "a2a-protocol.org"}
        ]
      }
    })
  end

  defp respond(:task, conn, _body, _opts), do: json(conn, 200, @task_working)

  # Counter-driven: the first `working` GETs answer WORKING, then COMPLETED.
  defp respond(:await, conn, _body, %{counter: counter, working: working}) do
    n = Elixir.Agent.get_and_update(counter, fn n -> {n, n + 1} end)
    json(conn, 200, if(n < working, do: @task_working, else: @task_done))
  end

  defp respond(:sse, conn, _body, _opts) do
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(200)

    {:ok, conn} = chunk(conn, "data: " <> Jason.encode!(%{"task" => @task_working}) <> "\n\n")
    {:ok, conn} = chunk(conn, "data: " <> Jason.encode!(%{"task" => @task_done}) <> "\n\n")
    conn
  end

  defp respond(:rpc, conn, body, _opts) do
    %{"id" => id, "method" => method} = Jason.decode!(body)

    result =
      case method do
        "ListTasks" ->
          %{"tasks" => [@task_working], "totalSize" => 1, "pageSize" => 1, "nextPageToken" => ""}

        "GetExtendedAgentCard" ->
          @card

        "SendMessage" ->
          %{"task" => @task_done}

        _ ->
          @task_working
      end

    json(conn, 200, %{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  # agent-card.json is gone (404), only the legacy agent.json path serves.
  defp respond(:legacy_card, %{request_path: "/.well-known/agent.json"} = conn, _body, _opts),
    do: json(conn, 200, @card)

  defp respond(:legacy_card, conn, _body, _opts), do: json(conn, 404, %{"error" => "gone"})

  defp respond(:card, conn, _body, _opts), do: json(conn, 200, @card)
end

defmodule AshA2A.ClientGapClosures.Trace do
  @moduledoc false
  @behaviour AshA2A.Protocol.Client.Interceptor

  @impl true
  def before_request(req), do: Req.Request.put_header(req, "x-w7-trace", "on")

  @impl true
  def after_response(_req, response) do
    send(Process.get(:w7_test) || self(), {:after_response, response.status})
    response
  end
end

defmodule AshA2A.ClientGapClosuresTest do
  @moduledoc """
  Real-wire court for the W7 client gaps: transport selection from the card,
  symmetric stream/resubscribe/list/extended-card ops, tenant, auth,
  interceptors, streaming error bodies, await_task, discovery options.
  Servers are real Bandit listeners; no mocks.
  """

  use ExUnit.Case, async: false

  @moduletag :serial_shard

  alias AshA2A.Protocol.{AgentCard, Client}
  alias AshA2A.Protocol.Client.Auth
  alias AshA2A.Protocol.SecurityScheme.APIKey
  alias AshA2A.Test.EphemeralHttp
  alias AshA2A.ClientGapClosures.Recorder

  defp serve!(mode, extra \\ %{}) do
    EphemeralHttp.start!({Recorder, Map.merge(%{test: self(), mode: mode}, extra)})
  end

  defp card(attrs) do
    struct!(
      AgentCard,
      Map.merge(
        %{name: "w7", description: "d", url: "http://127.0.0.1:1", version: "1.0.0", skills: []},
        Map.new(attrs)
      )
    )
  end

  defp iface(binding, url, extra \\ %{}) do
    Map.merge(%{url: url, protocol_binding: binding, protocol_version: "1.0"}, extra)
  end

  # -- G1: from_card ---------------------------------------------------------------

  test "from_card/2 takes the first supported interface in card order" do
    c =
      card(
        supported_interfaces: [
          iface("GRPC", "http://g"),
          iface("HTTP+JSON", "http://rest.example/a2a", %{tenant: "acme"}),
          iface("JSONRPC", "http://rpc.example")
        ]
      )

    assert {:ok, client} = Client.from_card(c)
    assert client.transport == :http_json
    assert client.url == "http://rest.example/a2a"
    assert client.tenant == "acme"
    assert client.card == c
    assert client.interface.protocol_binding == "HTTP+JSON"
    assert client.version == "1.0"
  end

  test "from_card/2 :preferred_bindings overrides card order" do
    c =
      card(
        supported_interfaces: [
          iface("HTTP+JSON", "http://rest.example"),
          iface("JSONRPC", "http://rpc.example")
        ]
      )

    assert {:ok, client} = Client.from_card(c, preferred_bindings: [:jsonrpc, :http_json])
    assert client.transport == :jsonrpc
    assert client.url == "http://rpc.example"
  end

  test "from_card/2 with no usable interface answers :no_supported_interface" do
    c = card(supported_interfaces: [iface("GRPC", "http://g")])
    assert {:error, :no_supported_interface} = Client.from_card(c)

    c2 = card(supported_interfaces: [iface("JSONRPC", "http://rpc.example")])

    assert {:error, :no_supported_interface} =
             Client.from_card(c2, preferred_bindings: [:http_json])
  end

  test "from_card/2 falls back to legacy card.url + preferred_transport" do
    c =
      card(
        supported_interfaces: [],
        url: "http://legacy.example",
        preferred_transport: "HTTP+JSON"
      )

    assert {:ok, client} = Client.from_card(c)
    assert client.transport == :http_json
    assert client.url == "http://legacy.example"

    c2 = card(supported_interfaces: [], url: "http://legacy.example")
    assert {:ok, %{transport: :jsonrpc}} = Client.from_card(c2)
  end

  test "from_card/2 refuses a required card extension the client did not declare" do
    ext = %AshA2A.Protocol.AgentExtension{uri: "https://example.com/ext/required", required: true}

    c =
      card(
        supported_interfaces: [iface("JSONRPC", "http://rpc.example")],
        capabilities: %{extensions: [ext]}
      )

    assert {:error, {:required_extension_not_supported, ["https://example.com/ext/required"]}} =
             Client.from_card(c)
  end

  # -- G8: capability negotiation ---------------------------------------------------

  test "known card without streaming/push answers typed local errors (no request sent)" do
    c =
      card(
        supported_interfaces: [iface("JSONRPC", "http://127.0.0.1:1")],
        capabilities: %{streaming: false, push_notifications: false}
      )

    {:ok, client} = Client.from_card(c)

    assert {:error, :streaming_not_supported} = Client.stream_message(client, "x")

    assert {:error, :push_notifications_not_supported} =
             Client.set_push_config(client, %AshA2A.Protocol.PushNotificationConfig{
               task_id: "t1",
               url: "http://127.0.0.1:2/hook"
             })
  end

  test "send_and_stream/3 degrades to send_message/3 when the card declares no streaming" do
    server = serve!(:rpc)

    c =
      card(
        supported_interfaces: [iface("JSONRPC", server.base_url)],
        capabilities: %{streaming: false}
      )

    {:ok, client} = Client.from_card(c)

    assert {:ok, [%AshA2A.Protocol.Task{}]} = Client.send_and_stream(client, "hello")
    assert_receive {:req, "POST", "/", _, _, body}
    assert %{"method" => "SendMessage"} = Jason.decode!(body)
  end

  # -- G2: symmetric ops --------------------------------------------------------------

  test "http_json stream_message/3 reads bare StreamResponse frames" do
    server = serve!(:sse)
    client = Client.new(server.base_url, transport: :http_json)

    assert {:ok, stream} = Client.stream_message(client, "go")
    events = Enum.to_list(stream)

    assert [%AshA2A.Protocol.Task{}, %AshA2A.Protocol.Task{}] = events
    assert_receive {:req, "POST", "/message:stream", _, headers, _}
    assert headers["accept"] =~ "text/event-stream"
  end

  test "http_json resubscribe/3 is GET /tasks/{id}:subscribe and streams" do
    server = serve!(:sse)
    client = Client.new(server.base_url, transport: :http_json)

    assert {:ok, stream} = Client.resubscribe(client, "t1")
    assert [%AshA2A.Protocol.Task{} | _] = Enum.to_list(stream)
    assert_receive {:req, "GET", "/tasks/t1:subscribe", _, _, _}
  end

  test "jsonrpc list_tasks/2 and get_extended_card/2 send the v1 methods" do
    server = serve!(:rpc)
    client = Client.new(server.base_url)

    assert {:ok, %{tasks: [%AshA2A.Protocol.Task{id: "t1"}], total_size: 1}} =
             Client.list_tasks(client, page_size: 1)

    assert_receive {:req, "POST", _, _, _, body}
    assert %{"method" => "ListTasks", "params" => %{"pageSize" => 1}} = Jason.decode!(body)

    assert {:ok, %AgentCard{name: "w7"}} = Client.get_extended_card(client)
    assert_receive {:req, "POST", _, _, _, body2}
    assert %{"method" => "GetExtendedAgentCard"} = Jason.decode!(body2)
  end

  # -- G4: tenant ----------------------------------------------------------------------

  test "tenant prefixes REST paths" do
    server = serve!(:task)
    client = Client.new(server.base_url, transport: :http_json, tenant: "acme")

    assert {:ok, %AshA2A.Protocol.Task{id: "t1"}} = Client.get_task(client, "t1")
    assert_receive {:req, "GET", "/acme/tasks/t1", _, _, _}
  end

  test "tenant is sent as params.tenant over JSON-RPC" do
    server = serve!(:rpc)
    client = Client.new(server.base_url, tenant: "acme")

    assert {:ok, %AshA2A.Protocol.Task{}} = Client.get_task(client, "t1")
    assert_receive {:req, "POST", _, _, _, body}

    assert %{"method" => "GetTask", "params" => %{"tenant" => "acme", "id" => "t1"}} =
             Jason.decode!(body)
  end

  # -- G5: streaming error bodies, Last-Event-ID, await_task -----------------------------

  test "stream error bodies are decoded into typed errors, not {:unexpected_status, _}" do
    server = serve!(:task_not_found)
    client = Client.new(server.base_url, transport: :http_json)

    assert {:error, :task_not_found} = Client.stream_message(client, "go")
    assert {:error, :task_not_found} = Client.resubscribe(client, "t1")
  end

  test ":last_event_id becomes the Last-Event-ID header on resubscribe" do
    server = serve!(:task_not_found)
    client = Client.new(server.base_url, transport: :http_json)

    assert {:error, :task_not_found} = Client.resubscribe(client, "t1", last_event_id: 42)
    assert_receive {:req, "GET", "/tasks/t1:subscribe", _, headers, _}
    assert headers["last-event-id"] == "42"
  end

  test "await_task/3 polls until the task is terminal" do
    {:ok, counter} = Elixir.Agent.start_link(fn -> 0 end)
    server = serve!(:await, %{counter: counter, working: 2})
    client = Client.new(server.base_url, transport: :http_json)

    assert {:ok, task} = Client.await_task(client, "t1", interval: 5, timeout: 5_000)
    assert AshA2A.Protocol.Task.terminal?(task)
    assert Elixir.Agent.get(counter, & &1) == 3
  end

  test "await_task/3 answers {:await_timeout, last_task} when the deadline passes" do
    server = serve!(:task)
    client = Client.new(server.base_url, transport: :http_json)

    assert {:error, {:await_timeout, %AshA2A.Protocol.Task{id: "t1"}}} =
             Client.await_task(client, "t1", interval: 5, timeout: 50)
  end

  # -- G6: auth, challenges, interceptors ----------------------------------------------------

  test "Auth.parse_challenge/1 parses scheme and auth-params" do
    assert [%{scheme: "Bearer", params: %{"realm" => "a2a", "error" => "invalid_token"}}] =
             Auth.parse_challenge(~s(Bearer realm="a2a", error=invalid_token))

    assert [%{scheme: "Basic", params: %{"realm" => "x y"}}, %{scheme: "Bearer"}] =
             Auth.parse_challenge([~s(Basic realm="x y"), "Bearer"])
  end

  test "Auth.credentials/2 places bearer, basic, api-key (header/query/cookie)" do
    c =
      card(
        security_schemes: %{
          "hdr" => %APIKey{name: "X-Key", in: "header"},
          "qry" => %APIKey{name: "k", in: "query"},
          "cok" => %APIKey{name: "sid", in: "cookie"},
          "bas" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "basic"},
          "bea" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}
        }
      )

    placed =
      Auth.credentials(
        %{"hdr" => "h1", "qry" => "q1", "cok" => "c1", "bas" => "user:pw", "bea" => "tok"},
        c
      )

    assert {"x-key", "h1"} in placed.headers
    assert {"authorization", "Bearer tok"} in placed.headers
    assert {"authorization", "Basic " <> Base.encode64("user:pw")} in placed.headers
    assert placed.query == [{"k", "q1"}]
    assert placed.cookies == [{"sid", "c1"}]
  end

  test ":auth map sends Authorization on the wire; callback form receives card requirements" do
    server = serve!(:task)
    client = Client.new(server.base_url, transport: :http_json, auth: %{"bearer_auth" => "tok-1"})
    assert {:ok, _} = Client.get_task(client, "t1")
    assert_receive {:req, "GET", "/tasks/t1", _, headers, _}
    assert headers["authorization"] == "Bearer tok-1"

    cb = fn requirements ->
      send(self(), {:requirements, requirements})
      [{"x-cb", "yes"}]
    end

    client2 = Client.new(server.base_url, transport: :http_json, auth: cb)
    assert {:ok, _} = Client.get_task(client2, "t1")
    assert_receive {:requirements, []}
    assert_receive {:req, "GET", "/tasks/t1", _, headers2, _}
    assert headers2["x-cb"] == "yes"
  end

  test "API-key auth in a query parameter reaches the server" do
    server = serve!(:task)
    c = card(security_schemes: %{"k" => %APIKey{name: "api_key", in: "query"}})

    client =
      Client.new(server.base_url, transport: :http_json, auth: %{"k" => "sekret"}, card: c)

    assert {:ok, _} = Client.get_task(client, "t1")
    assert_receive {:req, "GET", "/tasks/t1", "api_key=sekret", _, _}
  end

  test "401 surfaces the parsed WWW-Authenticate challenge; 403 surfaces the body" do
    unauth = serve!(:unauthorized)
    client = Client.new(unauth.base_url, transport: :http_json)

    assert {:error, {:unauthorized, [%{scheme: "Bearer", params: params}]}} =
             Client.get_task(client, "t1")

    assert params["realm"] == "a2a"

    # same typed error on the stream path
    assert {:error, {:unauthorized, [%{scheme: "Bearer"}]}} = Client.resubscribe(client, "t1")

    forbidden = serve!(:forbidden)
    client2 = Client.new(forbidden.base_url, transport: :http_json)
    assert {:error, {:forbidden, %{"error" => "nope"}}} = Client.get_task(client2, "t1")

    rpc_client = Client.new(unauth.base_url)
    assert {:error, {:unauthorized, _}} = Client.get_task(rpc_client, "t1")
  end

  test ":interceptors run before_request and after_response" do
    Process.put(:w7_test, self())
    server = serve!(:task)

    client =
      Client.new(server.base_url,
        transport: :http_json,
        interceptors: [AshA2A.ClientGapClosures.Trace]
      )

    assert {:ok, _} = Client.get_task(client, "t1")
    assert_receive {:req, "GET", "/tasks/t1", _, headers, _}
    assert headers["x-w7-trace"] == "on"
    assert_receive {:after_response, 200}
  end

  # -- G9: discovery -----------------------------------------------------------------------------

  test "discover/2 agent.json fallback is opt-in on 404" do
    server = serve!(:legacy_card)

    assert {:error, {:unexpected_status, 404}} = Client.discover(server.base_url)

    assert {:ok, %AgentCard{name: "w7"}} =
             Client.discover(server.base_url, agent_json_fallback: true)
  end

  test "discover/2 cache: true serves the second call from disk without a request" do
    dir = Path.join(System.tmp_dir!(), "w7_card_cache_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    server = serve!(:card)

    assert {:ok, %AgentCard{name: "w7"}} =
             Client.discover(server.base_url, cache: true, cache_dir: dir, max_age: 300)

    assert_receive {:req, "GET", "/.well-known/agent-card.json", _, _, _}

    assert {:ok, %AgentCard{name: "w7"}} =
             Client.discover(server.base_url, cache: true, cache_dir: dir, max_age: 300)

    refute_receive {:req, _, _, _, _, _}, 0
  end

  test "cached cards still pass the admission gate (verifier fun)" do
    dir = Path.join(System.tmp_dir!(), "w7_card_cache_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    server = serve!(:card)

    assert {:ok, _} = Client.discover(server.base_url, cache: true, cache_dir: dir)

    assert {:error, {:card_signature, :nope}} =
             Client.discover(server.base_url,
               cache: true,
               cache_dir: dir,
               verify_card_signature: fn _card -> {:error, :nope} end
             )

    assert {:ok, _} =
             Client.discover(server.base_url,
               cache: true,
               cache_dir: dir,
               verify_card_signature: fn _card -> :ok end
             )
  end
end

# --- SECTION 12: Original test/client_generation_support_test.exs ---
defmodule AshA2A.ClientGenerationSupportTest do
  @moduledoc """
  Pure V11 courts: generation gap / unsupported rules, annotate/2, timeline
  helpers and the client's local v1.1 guards. No network.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Protocol.{AgentCard, Artifact, Client, Message, TimelineEntry}
  alias AshA2A.Protocol.Client.Generation
  alias AshA2A.Protocol.Event.{ArtifactUpdate, MessageUpdate, StatusUpdate}
  alias AshA2A.Protocol.Task, as: T

  defp status(gen),
    do: %StatusUpdate{
      task_id: "t1",
      status: %T.Status{state: :working, timestamp: "2026-01-01T00:00:00Z"},
      generation: gen,
      final: false
    }

  defp snapshot(gen),
    do: %T{
      id: "t1",
      status: %T.Status{state: :working, timestamp: "2026-01-01T00:00:00Z"},
      generation: gen
    }

  describe "Generation.observe/2" do
    test "consecutive generations are ok" do
      {results, state} = Generation.fold([snapshot(1), status(2), status(3)])
      assert Enum.map(results, &elem(&1, 1)) == [:ok, :ok, :ok]
      assert state.last == 3
    end

    test "N then N+2 is a gap and tracking continues from the new generation" do
      {results, state} = Generation.fold([snapshot(1), status(2), status(4), status(5)])

      assert Enum.map(results, &elem(&1, 1)) == [:ok, :ok, {:gap, 3, 4}, :ok]
      assert state.last == 5
      assert state.gap == nil
    end

    test "generation 0 or absent marks the server unsupported, permanently" do
      {results, state} = Generation.fold([status(0), status(1), status(2)])
      assert Enum.map(results, &elem(&1, 1)) == [:unsupported, :unsupported, :unsupported]
      assert state.unsupported

      {results, state} = Generation.fold([snapshot(1), status(nil)])
      assert Enum.map(results, &elem(&1, 1)) == [:ok, :unsupported]
      assert state.unsupported
    end

    test "two consecutive identical generations mean unsupported" do
      {results, state} = Generation.fold([status(3), status(3), status(4)])
      assert Enum.map(results, &elem(&1, 1)) == [:ok, :unsupported, :unsupported]
      assert state.unsupported
    end

    test "a snapshot resynchronises across a jump without reporting a gap" do
      {results, state} = Generation.fold([status(2), snapshot(9), status(10)])
      assert Enum.map(results, &elem(&1, 1)) == [:ok, :ok, :ok]
      assert state.last == 10
    end

    test "non-generational elements are ignored" do
      msg = Message.new_user("hi")
      err = %AshA2A.Protocol.StreamError{code: "ABORTED"}
      {results, state} = Generation.fold([msg, err], Generation.new(last_seen: 4))
      assert Enum.map(results, &elem(&1, 1)) == [:ignore, :ignore]
      assert state.last == 4
    end

    test "resubscribe seed: first event after last_seen is checked against it" do
      assert {[{_, :ok}], _} = Generation.fold([status(5)], Generation.new(last_seen: 4))
      assert {[{_, {:gap, 5, 7}}], _} = Generation.fold([status(7)], Generation.new(last_seen: 4))
    end

    test "message and artifact updates carry generation too" do
      art = %ArtifactUpdate{
        task_id: "t1",
        artifact: %Artifact{parts: [], artifact_id: "a"},
        generation: 2
      }

      upd = %MessageUpdate{task_id: "t1", message: Message.new_user("x"), generation: 4}
      {results, _} = Generation.fold([snapshot(1), art, upd])
      assert Enum.map(results, &elem(&1, 1)) == [:ok, :ok, {:gap, 3, 4}]
    end
  end

  describe "Generation.annotate/2" do
    test "wraps elements and emits gap and unsupported annotations in order" do
      out = Enum.to_list(Generation.annotate([snapshot(1), status(3), status(3)]))

      assert [
               {:event, %T{}},
               {:gap, 2, 3},
               {:event, %StatusUpdate{generation: 3}},
               {:generation, :unsupported},
               {:event, %StatusUpdate{generation: 3}}
             ] = out
    end

    test "unsupported is announced once" do
      out = Enum.to_list(Generation.annotate([status(0), status(0), status(0)]))
      assert Enum.count(out, &(&1 == {:generation, :unsupported})) == 1
      assert Enum.count(out, &match?({:event, _}, &1)) == 3
    end
  end

  describe "timeline helpers" do
    defp entry(gen, kind), do: %TimelineEntry{entry: kind, generation: gen}

    defp task_with(timeline, artifacts \\ []),
      do: %T{
        id: "t1",
        status: %T.Status{state: :working, timestamp: "2026-01-01T00:00:00Z"},
        timeline: timeline,
        artifacts: artifacts
      }

    test "timeline/1 sorts by generation and skips unknown entries" do
      m = {:message, Message.new_user("a")}
      s = {:status, %T.Status{state: :working, timestamp: "2026-01-01T00:00:00Z"}}

      task = task_with([entry(3, s), entry(2, {:unknown, %{"x" => 1}}), entry(1, m)])

      assert [%TimelineEntry{generation: 1}, %TimelineEntry{generation: 3}] =
               Client.timeline(task)
    end

    test "interleave_artifacts/1 orders by start generation, entries first on ties" do
      s = {:status, %T.Status{state: :working, timestamp: "2026-01-01T00:00:00Z"}}
      m = {:message, Message.new_user("a")}

      task =
        task_with(
          [entry(1, m), entry(2, s), entry(4, s)],
          [
            %Artifact{parts: [], artifact_id: "late", start_generation: 4},
            %Artifact{parts: [], artifact_id: "mid", start_generation: 2, end_generation: 3},
            %Artifact{parts: [], artifact_id: "none"}
          ]
        )

      assert [
               {:entry, %{generation: 1}},
               {:entry, %{generation: 2}},
               {:artifact, %{artifact_id: "mid"}},
               {:entry, %{generation: 4}},
               {:artifact, %{artifact_id: "late"}},
               {:artifact, %{artifact_id: "none"}}
             ] = Client.interleave_artifacts(task)
    end
  end

  describe "client v1.1 defaults and local guards" do
    test "default A2A-Version is 1.1; version: \"1.0\" overrides" do
      assert Client.new("http://127.0.0.1:1").version == "1.1"
      assert Client.new("http://127.0.0.1:1", version: "1.0").version == "1.0"
      pairs = header_pairs(Client.new("http://127.0.0.1:1").req.headers)
      assert {"a2a-version", "1.1"} in pairs
    end

    test "artifact_updates refused locally without the userArtifacts capability" do
      card = %AgentCard{
        name: "n",
        description: "d",
        url: "http://127.0.0.1:1",
        version: "1",
        skills: [],
        capabilities: %{streaming: true}
      }

      client = Client.new("http://127.0.0.1:1", transport: :http_json, card: card)

      assert {:error, :user_artifacts_not_supported} =
               Client.send_message(client, nil,
                 task_id: "t1",
                 artifact_updates: [%{"taskId" => "t1"}]
               )

      assert {:error, :user_artifacts_not_supported} =
               Client.stream_message(client, "x", artifact_updates: [%{"taskId" => "t1"}])
    end

    test "message is required unless artifact_updates stand in" do
      client = Client.new("http://127.0.0.1:1", transport: :http_json)
      assert {:error, :message_required} = Client.send_message(client, nil)
    end
  end

  defp header_pairs(headers) when is_map(headers) do
    for {k, vs} <- headers, v <- List.wrap(vs), do: {k, v}
  end

  defp header_pairs(headers), do: headers
end

# --- SECTION 13: Original test/client_live_transport_test.exs ---
defmodule AshA2A.ClientLiveTransportTest.RpcMismatchPlug do
  @moduledoc false
  # Real hand-written JSON-RPC server: answers every call with a v1.1
  # TASK_GENERATION_MISMATCH (-32010) error body.
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    {:ok, _body, conn} = read_body(conn)

    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "error" => %{
          "code" => -32_010,
          "message" => "generation mismatch",
          "data" => [
            %{
              "@type" => "type.googleapis.com/google.rpc.ErrorInfo",
              "reason" => "TASK_GENERATION_MISMATCH",
              "metadata" => %{"expectedGeneration" => "9", "actualGeneration" => "2"}
            }
          ]
        }
      })

    conn |> put_resp_content_type("application/json") |> send_resp(200, body)
  end
end

defmodule AshA2A.ClientLiveTransportTest do
  @moduledoc """
  V11 integration courts: the v1.1 client against the real `HTTPJSON` binding on
  a real Bandit listener over real `AshA2A.Protocol.Agent` GenServers.
  ifGenerationMatch mismatch mapping, long-poll, resubscribe with
  lastSeenGeneration, and the Live open/send/close session. Bounded by
  receive timeouts and Task.await deadlines; no sleeps.
  """

  use ExUnit.Case, async: false

  @moduletag :serial_shard

  alias AshA2A.Protocol.Client
  alias AshA2A.Protocol.Client.Live
  alias AshA2A.Protocol.Event.{MessageUpdate, StatusUpdate}
  alias AshA2A.Protocol.Task, as: T
  alias AshA2A.Test.EphemeralHttp
  alias AshA2A.Transport.HTTPJSON, as: Binding

  defmodule OpenAgent do
    use AshA2A.Protocol.Agent,
      name: "v11-client-open",
      description: "streaming, keeps tasks open",
      capabilities: %{streaming: true}

    @impl AshA2A.Protocol.Agent
    def handle_message(_message, _ctx),
      do: {:input_required, [AshA2A.Protocol.Part.Text.new("more?")]}
  end

  defmodule ArtAgent do
    use AshA2A.Protocol.Agent,
      name: "v11-client-art",
      description: "streaming + client artifacts",
      capabilities: %{streaming: true, user_artifacts: true}

    @impl AshA2A.Protocol.Agent
    def handle_message(_message, _ctx),
      do: {:input_required, [AshA2A.Protocol.Part.Text.new("more?")]}
  end

  setup do
    start_supervised!({OpenAgent, []})
    start_supervised!({ArtAgent, []})

    unless Process.whereis(AshA2A.Transport.Live.Registry),
      do: start_supervised!(AshA2A.Transport.Live.Supervisor)

    open =
      EphemeralHttp.start!(
        {Binding, Binding.init(agent: OpenAgent, base_url: "http://127.0.0.1/open")}
      )

    art =
      EphemeralHttp.start!(
        {Binding, Binding.init(agent: ArtAgent, base_url: "http://127.0.0.1/art")}
      )

    %{
      open: Client.new(open.base_url, transport: :http_json, version: "1.1"),
      art: Client.new(art.base_url, transport: :http_json, version: "1.1"),
      art_url: art.base_url
    }
  end

  test "ifGenerationMatch mismatch maps to {:task_generation_mismatch, details}", %{art: art} do
    assert {:ok, %T{id: id}} = Client.send_message(art, "hello")

    assert {:error, {:task_generation_mismatch, details}} =
             Client.send_message(art, "more", task_id: id, if_generation_match: 9_999)

    assert is_map(details)

    # artifact-only path: deterministic check against the owned task
    assert {:error, {:task_generation_mismatch, _}} =
             Client.send_message(art, nil,
               task_id: id,
               if_generation_match: 9_999,
               artifact_updates: [
                 %{
                   "taskId" => id,
                   "artifact" => %{"artifactId" => "a1", "parts" => [%{"text" => "x"}]}
                 }
               ]
             )
  end

  test "JSON-RPC -32010 maps to {:task_generation_mismatch, details}" do
    server = EphemeralHttp.start!(AshA2A.ClientLiveTransportTest.RpcMismatchPlug)
    client = Client.new(server.base_url)

    assert {:error, {:task_generation_mismatch, %{metadata: %{"expectedGeneration" => "9"}}}} =
             Client.get_task(client, "t1")
  end

  test "get_task long-poll returns once the generation advances", %{open: client} do
    assert {:ok, %T{id: id, generation: gen}} = Client.send_message(client, "hello")

    poll =
      Task.async(fn -> Client.get_task(client, id, current_generation: gen, timeout: 10_000) end)

    assert {:ok, %T{}} = Client.send_message(client, "again", task_id: id)

    assert {:ok, %T{generation: new_gen}} = Task.await(poll, 12_000)
    assert new_gen > gen
  end

  test "get_task timeline_length bounds the returned timeline", %{open: client} do
    assert {:ok, %T{id: id}} = Client.send_message(client, "one")
    assert {:ok, _} = Client.send_message(client, "two", task_id: id)

    assert {:ok, %T{timeline: timeline}} = Client.get_task(client, id, timeline_length: 1)
    assert length(timeline) <= 1
  end

  test "resubscribe with last_seen_generation sends no snapshot first", %{open: client} do
    assert {:ok, %T{id: id, generation: gen}} = Client.send_message(client, "hello")

    assert {:ok, stream} =
             Client.resubscribe(client, id,
               last_seen_generation: gen,
               timeout: 10_000,
               track_generation: true
             )

    assert {:ok, _} = Client.send_message(client, "next", task_id: id)

    assert [{:event, first} | _] = Enum.take(stream, 1)
    refute match?(%T{}, first)

    assert match?(%StatusUpdate{}, first) or match?(%MessageUpdate{}, first) or
             match?(%AshA2A.Protocol.Event.ArtifactUpdate{}, first)
  end

  test "Live open / send / close over HTTP+JSON", %{open: client} do
    assert {:ok, %T{id: id}} = Client.send_message(client, "hello")

    assert {:ok, %{events: events, session: session}} =
             Live.open(client, %{"subscribe" => %{"id" => id}}, timeout: 10_000)

    follow_up = %{AshA2A.Protocol.Message.new_user("more") | task_id: id}

    seen =
      Enum.reduce_while(events, [], fn event, acc ->
        acc = acc ++ [event]

        case event do
          %T{} ->
            assert {:ok, %T{id: ^id}} = Live.send_message(session, follow_up)
            {:cont, acc}

          %StatusUpdate{} ->
            {:halt, acc}

          %MessageUpdate{} ->
            {:halt, acc}

          _ ->
            {:cont, acc}
        end
      end)

    assert [%T{id: ^id} | rest] = seen
    assert rest != []
    assert :ok = Live.close(session)
  end

  test "Live.open refuses a JSON-RPC client", %{art_url: url} do
    assert {:error, {:transport_unsupported, :live}} =
             Live.open(Client.new(url), %{"subscribe" => %{"id" => "t"}})
  end
end

# --- SECTION 14: Original test/docs_nav_coverage_test.exs ---
defmodule DocsNavCoverageTest do
  @moduledoc """
  Nav-coverage court: every file in the Diátaxis quadrants
  (docs/{tutorials,how-to,reference,explanation}) must be indexed in docs/README.md,
  and every docs/README.md entry must point at a real file. Also checks that every
  relative .md fragment link inside docs/ resolves to a real heading.
  Ported from the xaas docs/claude/diataxis/README.md pattern.
  """

  use ExUnit.Case, async: true

  @docs_dir Path.join(File.cwd!(), "docs")
  @readme Path.join(@docs_dir, "README.md")
  @quadrants ~w(tutorials how-to reference explanation)

  defp readme_entries do
    readme = File.read!(@readme)

    ~r{\]\(([^)#\s]+\.md)\)}
    |> Regex.scan(readme, capture: :all_but_first)
    |> List.flatten()
    |> MapSet.new()
  end

  defp quadrant_files do
    @quadrants
    |> Enum.flat_map(fn q ->
      @docs_dir
      |> Path.join("#{q}/*.md")
      |> Path.wildcard()
      |> Enum.map(fn f -> "#{q}/#{Path.basename(f)}" end)
    end)
    |> MapSet.new()
  end

  defp slugify(line) do
    line
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^\w\s-]/, "")
    |> String.replace(~r/\s+/, "-")
  end

  defp headings(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.filter(&(&1 =~ ~r/^#+\s/))
    |> Enum.map(&slugify(String.replace(&1, ~r/^#+\s/, "")))
  end

  test "docs/README.md exists and is the nav surface" do
    assert File.exists?(@readme)
  end

  # README -> files
  test "every docs/README.md entry points at a real file" do
    orphan_entries =
      readme_entries()
      |> Enum.reject(&File.exists?(Path.join(@docs_dir, &1)))

    assert orphan_entries == [],
           "docs/README.md links to missing files: #{inspect(orphan_entries)}"
  end

  # files -> README
  test "every quadrant file is indexed in docs/README.md (both directions)" do
    entries = readme_entries()
    files = quadrant_files()

    assert MapSet.subset?(files, entries),
           "quadrant files missing from docs/README.md: #{inspect(MapSet.difference(files, entries) |> MapSet.to_list())}"
  end

  # fragment anchors inside docs/
  test "every relative .md fragment link in docs/ resolves to a real heading" do
    files = MapSet.to_list(quadrant_files()) ++ ["README.md"]

    Enum.each(files, fn f ->
      path = Path.join(@docs_dir, f)
      dir = Path.dirname(path)
      text = File.read!(path)

      ~r{\]\(([^)#\s]+\.md)(#[^)\s]+)\)}
      |> Regex.scan(text, capture: :all_but_first)
      |> Enum.each(fn [rel, frag] ->
        target = Path.join(dir, rel)

        # only in-docs relative targets are in scope; skip anything outside docs/
        if File.exists?(target) and String.contains?(Path.expand(target), @docs_dir) do
          frag = String.trim_leading(frag, "#")
          heads = headings(target)

          assert frag in heads,
                 "broken anchor in #{f}: #{rel}##{frag} " <>
                   "(headings: #{inspect(heads)})"
        end
      end)
    end)
  end
end

# --- SECTION 15: Original test/downgrade_test.exs ---
defmodule AshA2A.Protocol.DowngradeTest do
  use ExUnit.Case, async: true

  alias AshA2A.Protocol.Downgrade

  @task %{
    "id" => "t1",
    "generation" => 3,
    "timeline" => [%{"g" => 1}],
    "status" => %{"state" => "TASK_STATE_WORKING", "message" => %{"role" => "ROLE_AGENT"}},
    "artifacts" => [
      %{
        "artifactId" => "a1",
        "role" => "x",
        "startGeneration" => 1,
        "endGeneration" => 2,
        "parts" => [%{"text" => "hi"}]
      }
    ]
  }

  test "applies?/1" do
    assert Downgrade.applies?("1.0")
    assert Downgrade.applies?("0.3")
    refute Downgrade.applies?("1.1")
    refute Downgrade.applies?("2.0")
    refute Downgrade.applies?(nil)
    refute Downgrade.applies?("garbage")
  end

  test "nil and >=1.1 pass through unchanged" do
    assert Downgrade.to_wire(@task, nil) == @task
    assert Downgrade.to_wire(@task, "1.1") == @task
  end

  test "1.0 drops v1.1 fields, keeps message role" do
    out = Downgrade.to_wire(@task, "1.0")
    refute Map.has_key?(out, "generation")
    refute Map.has_key?(out, "timeline")
    assert out["status"]["message"]["role"] == "ROLE_AGENT"
    [art] = out["artifacts"]
    assert art == %{"artifactId" => "a1", "parts" => [%{"text" => "hi"}]}
  end

  test "event maps lose generation" do
    ev = %{"result" => %{"statusUpdate" => %{"taskId" => "t", "generation" => 2}}}
    assert Downgrade.to_wire(ev, "1.0") == %{"result" => %{"statusUpdate" => %{"taskId" => "t"}}}
  end

  test "messageUpdate frames dropped" do
    frame = %{"result" => %{"messageUpdate" => %{"x" => 1}}}
    assert Downgrade.drop_frame?(frame, "1.0")
    assert Downgrade.drop_frame?(%{"messageUpdate" => %{}}, "1.0")
    refute Downgrade.drop_frame?(frame, nil)
    refute Downgrade.drop_frame?(%{"statusUpdate" => %{}}, "1.0")
    assert Downgrade.to_wire(frame, "1.0") == :drop
    assert Downgrade.to_wire(frame, nil) == frame
    assert Downgrade.to_wire([frame, %{"a" => 1}], "1.0") == [%{"a" => 1}]
  end
end

# --- SECTION 16: Original test/dsl_card_surface_test.exs ---
defmodule AshA2A.DslCardSurface.Res do
  @moduledoc false

  use Ash.Resource,
    domain: AshA2A.DslCardSurface.Home,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  alias AshA2A.Protocol.Part

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])

    action :needs_more, :term do
      public?(true)

      run(fn _input, _ctx ->
        {:ok, {:input_required, [Part.Text.new("need more")]}}
      end)
    end

    action :needs_auth, :term do
      public?(true)

      run(fn _input, _ctx ->
        {:ok, {:auth_required, [Part.Text.new("log in")]}}
      end)
    end

    action :many, :term do
      public?(true)

      run(fn _input, _ctx ->
        {:ok,
         %AshA2A.Artifacts{
           artifacts: [[Part.Text.new("a")], %{name: "second", parts: [Part.Text.new("b")]}]
         }}
      end)
    end
  end

  a2a do
    skill(:echo, :read,
      examples: ["echo hello"],
      input_modes: ["text/plain", "application/json"],
      output_modes: ["application/json"],
      streaming?: true
    )

    skill(:needs_more, :needs_more, consequence: :observe)
    skill(:needs_auth, :needs_auth, consequence: :observe)
    skill(:many, :many, consequence: :observe)
  end
end

defmodule AshA2A.DslCardSurface.Home do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.DslCardSurface.Res)
  end
end

defmodule AshA2A.DslCardSurface.CardDomain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A, AshA2A.Domain], validate_config_inclusion?: false

  resources do
    resource(AshA2A.DslCardSurface.Res)
  end

  agent do
    name("w11-card")
    default_input_modes(["application/json"])
    default_output_modes(["application/json", "text/plain"])
    sign_card("key-1")
  end

  security do
    security_scheme(:token, :bearer, bearer_format: "JWT")
    security_scheme(:key, :api_key, location: :query, param_name: "k")
    security_scheme(:basic, :http, http_scheme: "basic")

    security_scheme(:oauth, :oauth2,
      oauth_flows: %{
        "clientCredentials" => %{
          "tokenUrl" => "https://auth.example.com/token",
          "scopes" => %{"read" => "read things"}
        }
      },
      scopes: ["read"]
    )

    security_scheme(:oidc, :openid_connect, openid_url: "https://auth.example.com/.well-known")
    security_scheme(:tls, :mtls)

    requirements(["token", "oauth"])
    requirement_scopes(%{"oauth" => ["read"]})
  end

  transport do
    base_url("https://w11.example.com")
    extended_agent_card(true)
    push_allowed_hosts(["hooks.example.com"])
    push_retry(max_attempts: 3, backoff_ms: 200)

    extension("https://example.com/ext/one", required: true, description: "one")
    extension("https://example.com/ext/two", params: %{"k" => "v"})
  end
end

defmodule AshA2A.DslCardSurfaceTest do
  use ExUnit.Case, async: true

  import Spark.Test, only: [assert_dsl_error: 2]

  alias AshA2A.Domain.Info
  alias AshA2A.DslCardSurface.{CardDomain, Res}

  describe "skill entity" do
    test "examples/modes/streaming? are copied into the compiled capability" do
      skill = Enum.find(AshA2A.Info.capability_index(Res), &(&1.action == :read))

      assert skill.examples == ["echo hello"]
      assert skill.input_modes == ["text/plain", "application/json"]
      assert skill.output_modes == ["application/json"]
      assert skill.streaming? == true
    end

    test "the card skill projects examples and modes; undeclared skills omit them" do
      card = AshA2A.Info.agent_card(Res)
      echo = Enum.find(card.skills, &String.ends_with?(&1.id, ".read"))
      other = Enum.find(card.skills, &String.ends_with?(&1.id, ".many"))

      assert echo.examples == ["echo hello"]
      assert echo.input_modes == ["text/plain", "application/json"]
      assert echo.output_modes == ["application/json"]
      refute Map.has_key?(other, :examples)
      refute Map.has_key?(other, :input_modes)
    end

    test "kill: a non-MIME mode fails compilation" do
      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule Elixir.AshA2A.W11Test.BadMode do
            @moduledoc false
            use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets, extensions: [AshA2A]

            attributes do
              uuid_primary_key(:id)
            end

            actions do
              defaults([:read])
            end

            a2a do
              skill(:echo, :read, input_modes: ["not a mime"])
            end
          end
        end

      assert error.message =~ "refused_mode_not_mime"
    end

    test "kill: a security requirement naming no declared scheme fails compilation" do
      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule Elixir.AshA2A.W11Test.BadSecurityDomain do
            @moduledoc false
            use Ash.Domain,
              extensions: [AshA2A, AshA2A.Domain],
              validate_config_inclusion?: false

            resources do
              resource(AshA2A.DslCardSurface.Res)
            end

            agent do
              name("bad-sec")
            end

            transport do
              base_url("https://x.example.com")
            end

            security do
              security_scheme(:token, :bearer)
            end

            a2a do
              skill(:echo, AshA2A.DslCardSurface.Res, :read,
                security_requirements: [%{"ghost" => []}]
              )
            end
          end
        end

      assert error.message =~ "refused_security_requirement_undeclared"
    end
  end

  describe "domain config" do
    test "agent modes and sign_card are persisted" do
      assert Info.agent_default_input_modes(CardDomain) == ["application/json"]
      assert Info.agent_default_output_modes(CardDomain) == ["application/json", "text/plain"]
      assert Info.agent_sign_card(CardDomain) == "key-1"
    end

    test "builder prefers declared default modes over its own default" do
      card = AshA2A.Info.agent_card(CardDomain)
      assert card.default_input_modes == ["application/json"]
      assert card.default_output_modes == ["application/json", "text/plain"]
    end

    test "all security scheme kinds project to protocol structs" do
      schemes = AshA2A.Info.agent_card(CardDomain).security_schemes

      assert %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer", bearer_format: "JWT"} =
               schemes["token"]

      assert %AshA2A.Protocol.SecurityScheme.APIKey{name: "k", in: "query"} = schemes["key"]
      assert %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "basic"} = schemes["basic"]

      assert %AshA2A.Protocol.SecurityScheme.OAuth2{flows: %{"clientCredentials" => _}} =
               schemes["oauth"]

      assert %AshA2A.Protocol.SecurityScheme.OpenIDConnect{
               open_id_connect_url: "https://auth.example.com/.well-known"
             } = schemes["oidc"]

      assert %AshA2A.Protocol.SecurityScheme.MutualTLS{} = schemes["tls"]
    end

    test "per-requirement scopes reach card.security" do
      security = AshA2A.Info.agent_card(CardDomain).security
      assert %{"token" => []} in security
      assert %{"oauth" => ["read"]} in security
    end

    test "extensions merge into capabilities; extended_agent_card is declared" do
      caps = AshA2A.Info.agent_card(CardDomain).capabilities

      assert caps.extended_agent_card == true

      assert [
               %AshA2A.Protocol.AgentExtension{
                 uri: "https://example.com/ext/one",
                 required: true
               },
               %AshA2A.Protocol.AgentExtension{
                 uri: "https://example.com/ext/two",
                 params: %{"k" => "v"}
               }
             ] = caps.extensions
    end

    test "push policy options are persisted" do
      assert Info.push_allowed_hosts(CardDomain) == ["hooks.example.com"]
      assert Info.push_retry(CardDomain) == [max_attempts: 3, backoff_ms: 200]
    end

    test "kill: duplicate extension uri fails compilation" do
      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule Elixir.AshA2A.W11Test.DupExt do
            @moduledoc false
            use Ash.Domain, extensions: [AshA2A.Domain]

            agent do
              name("dup")
            end

            transport do
              base_url("https://x.example.com")
              extension("https://example.com/e")
              extension("https://example.com/e")
            end
          end
        end

      assert error.message =~ "duplicate"
    end

    test "kill: oauth2 without oauth_flows fails compilation" do
      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule Elixir.AshA2A.W11Test.BadOauth do
            @moduledoc false
            use Ash.Domain, extensions: [AshA2A.Domain]

            agent do
              name("bad-oauth")
            end

            transport do
              base_url("https://x.example.com")
            end

            security do
              security_scheme(:o, :oauth2)
            end
          end
        end

      assert error.message =~ "oauth_flows"
    end
  end

  describe "mount tenant / protocol_version" do
    defmodule TenantAgent do
      @moduledoc false
      use AshA2A.Agent,
        resource_or_domain: AshA2A.DslCardSurface.Res,
        name: "w11_tenant_agent",
        public_skills: [:echo]
    end

    defmodule TenantDomain do
      @moduledoc false
      use Ash.Domain, extensions: [AshA2A.Domain]

      agent do
        name("tenant-domain")
      end

      transport do
        base_url("https://t.example.com")

        mount agent: AshA2A.DslCardSurfaceTest.TenantAgent,
              path: "/t",
              binding: :jsonrpc,
              tenant: "acme",
              protocol_version: "1.0"
      end
    end

    test "supported_interfaces carries tenant and protocol_version only when declared" do
      assert [
               %{
                 url: "https://t.example.com/t",
                 protocol_binding: "JSONRPC",
                 tenant: "acme",
                 protocol_version: "1.0"
               }
             ] = Info.supported_interfaces(TenantDomain)
    end

    test "builder normalization keeps the tenant on the interface" do
      card =
        AshA2A.CapabilityIndex.AgentCardBuilder.build_agent_card([],
          supported_interfaces: [
            %{url: "https://t.example.com/t", protocol_binding: "JSONRPC", tenant: "acme"}
          ]
        )

      version = AshA2A.Protocol.Version.protocol_version()
      assert [%{tenant: "acme", protocol_version: ^version}] = card.supported_interfaces
    end
  end

  describe "generic-action return contract" do
    alias AshA2A.Protocol.{Message, Part}

    defp dispatch(skill),
      do: AshA2A.Dispatcher.dispatch_observe(skill, Message.new_user("hi"), Res)

    test "{:input_required, parts} replies input_required" do
      assert {:input_required, [%Part.Text{text: "need more"}]} = dispatch(:needs_more)
    end

    test "{:auth_required, parts} replies an untagged auth_required error" do
      assert {:error, {:auth_required, [%Part.Text{text: "log in"}]}} = dispatch(:needs_auth)
    end

    test "%AshA2A.Artifacts{} flattens artifact parts in order" do
      assert {:reply, [%Part.Text{text: "a"}, %Part.Text{text: "b"}]} = dispatch(:many)
    end
  end
end

# --- SECTION 17: Original test/dsl_mapping_card_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.DslMappingCardFixtures.MappedResource do
  @moduledoc false
  use Ash.Resource,
    domain: AshA2A.DslMappingCardFixtures.MappedDomain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])

    action :shout, :string do
      argument(:query, :string, allow_nil?: false)
      run(fn input, _context -> {:ok, String.upcase(input.arguments.query)} end)
    end
  end

  policies do
    policy always() do
      authorize_if(always())
    end
  end

  a2a do
    skill(:shout, :shout,
      consequence: :observe,
      argument_mapping: %{"q" => :query},
      get?: true,
      lease_required?: true
    )

    skill(:plain_read, :read, get?: false, lease_required?: false)
  end
end

defmodule AshA2A.DslMappingCardFixtures.MappedDomain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.DslMappingCardFixtures.MappedResource)
  end
end

defmodule AshA2A.DslMappingCardFixtures.Agent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.DslMappingCardFixtures.MappedResource,
    name: "lane11_agent",
    public_skills: [:plain_read]
end

defmodule AshA2A.DslMappingCardFixtures.CardDomain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A, AshA2A.Domain], validate_config_inclusion?: false

  resources do
    resource(AshA2A.DslMappingCardFixtures.MappedResource)
  end

  agent do
    name "lane11-card"
    description "Lane 11 card description"
    version "9.8.7"
    provider "Lane Eleven Org"
    documentation_url "https://docs.example.com/lane11"
    icon_url "https://icons.example.com/lane11.png"
  end

  security do
    security_scheme :token, :bearer
    security_scheme :key, :api_key
    security_scheme :open, :none
    requirements ["token"]
  end

  transport do
    base_url "https://lane11.example.com"
    streaming false
    push_notifications true
  end
end

defmodule AshA2A.DslMappingCardTest do
  use ExUnit.Case, async: true

  import Spark.Test

  alias AshA2A.DslMappingCardFixtures.CardDomain
  alias AshA2A.DslMappingCardFixtures.MappedResource

  defp compile(quoted), do: Code.compile_quoted(quoted)

  # Spark converts verifier errors to stderr warnings; Spark.Test collects the
  # real %Spark.Error.DslError{} values the verifiers returned.
  defp first_error(quoted) do
    errors =
      dsl_errors do
        compile(quoted)
      end
      |> Enum.flat_map(fn {_module, errors} -> errors end)

    assert errors != [], "expected a verifier error but none was collected"
    hd(errors)
  end

  defp warning_messages(quoted) do
    dsl_warnings do
      compile(quoted)
    end
    |> Enum.flat_map(fn {_module, warnings} -> Enum.map(warnings, &elem(&1, 0)) end)
    |> Enum.join("\n")
  end

  # Resource fixture builder: `extra` is spliced into the resource body.
  defp resource_quoted(name, actions, extra) do
    mod = Module.concat(AshA2A.DslLane11Gen, name)

    quote do
      defmodule unquote(mod) do
        use Ash.Resource,
          domain: nil,
          validate_domain_inclusion?: false,
          data_layer: Ash.DataLayer.Ets,
          extensions: [AshA2A]

        attributes do
          uuid_primary_key(:id)
          attribute(:label, :string, public?: true)
        end

        actions do
          unquote(actions)
        end

        unquote(extra)
      end
    end
  end

  defp domain_quoted(name, body) do
    mod = Module.concat(AshA2A.DslLane11Gen, name)

    quote do
      defmodule unquote(mod) do
        use Ash.Domain, extensions: [AshA2A.Domain], validate_config_inclusion?: false
        unquote(body)
      end
    end
  end

  describe "compiler projection (argument_mapping / get? / lease_required?)" do
    test "override fields are carried into the compiled skill and explicit false is kept" do
      {:ok, shout} = AshA2A.Info.skill(MappedResource, :shout)
      assert shout.argument_mapping == %{"q" => :query}
      assert shout.get? == true
      assert shout.lease_required? == true

      {:ok, plain} = AshA2A.Info.skill(MappedResource, :plain_read)
      assert plain.argument_mapping == %{}
      assert plain.get? == false
      assert plain.lease_required? == false
    end

    test "argument_mapping drives real end-to-end dispatch through the Executor" do
      {:ok, skill} = AshA2A.Info.skill(MappedResource, :shout)

      message =
        AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(%{"q" => "hello"})])

      assert {:ok, [%AshA2A.Protocol.Part.Data{data: data}]} =
               AshA2A.Executor.execute(skill, message, auth_identity: %{sub: "alice"})

      assert inspect(data) =~ "HELLO"
    end
  end

  describe "duplicate overrides" do
    test "two overrides of the same {resource, action} are refused at compile time" do
      quoted =
        resource_quoted(
          "DupOverride",
          quote(do: defaults([:read])),
          quote do
            a2a do
              skill(:first, :read)
              skill(:second, :read)
            end
          end
        )

      error = first_error(quoted)
      assert error.message =~ "REFUSED_DUPLICATE_ACTION_OVERRIDE"
    end
  end

  describe "authority gate topology" do
    test "gate :open reports every default public create/update/destroy offender" do
      quoted =
        resource_quoted(
          "OpenGate",
          quote(do: defaults([:read, :destroy, create: [:label], update: [:label]])),
          quote do
            authority do
              gate :open
            end
          end
        )

      error = first_error(quoted)
      assert error.path == [:authority, :gate]
      assert error.message =~ ":create"
      assert error.message =~ ":update"
      assert error.message =~ ":destroy"
      assert error.message =~ "3 exposed action(s)"
    end

    test "gate :open with only reads (and an expose? false mutation) compiles" do
      quoted =
        resource_quoted(
          "OpenGateReadOnly",
          quote(do: defaults([:read, create: [:label]])),
          quote do
            authority do
              gate :open
            end

            a2a do
              skill(:hidden_create, :create, expose?: false)
            end
          end
        )

      stderr = warning_messages(quoted)
      assert stderr =~ "declared but not enforced"
    end
  end

  describe "authority / hooks are never silently inert" do
    test "non-default lease_duration_ms and hooks emit declared-but-not-enforced warnings" do
      quoted =
        resource_quoted(
          "InertSections",
          quote(do: defaults([:read])),
          quote do
            authority do
              lease_duration_ms 5_000
            end

            hooks do
              pre_dispatch [:audit_hook]
            end
          end
        )

      stderr = warning_messages(quoted)
      assert stderr =~ "lease_duration_ms 5000 is declared but not enforced"
      refute stderr =~ "hooks pre_dispatch"
    end

    test "defaults compile without any inert-section warning" do
      quoted = resource_quoted("CleanSections", quote(do: defaults([:read])), nil)
      stderr = warning_messages(quoted)
      refute stderr =~ "not enforced"
    end

    test "authority and hooks values persist and read back through AshA2A.Info" do
      mod = Module.concat(AshA2A.DslLane11Gen, "PersistedSections")

      compile(
        resource_quoted(
          "PersistedSections",
          quote(do: defaults([:read])),
          quote do
            authority do
              lease_duration_ms 7_000
            end

            hooks do
              post_dispatch [:after_hook]
            end
          end
        )
      )

      assert AshA2A.Info.lease_duration_ms(mod) == 7_000
      assert AshA2A.Info.hooks(mod) == %{pre_dispatch: [], post_dispatch: [:after_hook]}
      assert AshA2A.Info.authority_gate(mod) == :two_port
    end
  end

  describe "skill verification" do
    test "on_cancel naming a missing module is refused" do
      quoted =
        resource_quoted(
          "BadOnCancel",
          quote(do: defaults([:read])),
          quote do
            a2a do
              skill(:r, :read, on_cancel: Elixir.AshA2A.DslLane11Gen.NoSuchHook)
            end
          end
        )

      error = first_error(quoted)
      assert error.message =~ "refused_on_cancel_target"
    end

    test "on_cancel MFA with a missing function arity is refused" do
      quoted =
        resource_quoted(
          "BadOnCancelMfa",
          quote(do: defaults([:read])),
          quote do
            a2a do
              skill(:r, :read, on_cancel: {Kernel, :definitely_not_a_function, [1]})
            end
          end
        )

      error = first_error(quoted)
      assert error.message =~ "does not export definitely_not_a_function/4"
    end

    test "an existing on_cancel MFA compiles" do
      quoted =
        resource_quoted(
          "GoodOnCancelMfa",
          quote(do: defaults([:read])),
          quote do
            a2a do
              skill(:r, :read, on_cancel: {Kernel, :apply, []})
            end
          end
        )

      assert [] ==
               dsl_errors(do: compile(quoted))
               |> Enum.flat_map(fn {_m, errors} -> errors end)
    end

    test "hddl fact args outside the operator parameters are refused" do
      quoted =
        resource_quoted(
          "BadHddlArgs",
          quote(do: defaults([:read])),
          quote do
            a2a do
              skill :r, :read do
                hddl_operator(
                  parameters: [:a],
                  preconditions: [{:holds, [:a, :zzz]}]
                )
              end
            end
          end
        )

      error = first_error(quoted)
      assert error.message =~ "refused_hddl_fact_args"
    end

    test "more than one hddl_operator per skill is refused" do
      quoted =
        resource_quoted(
          "TwoHddl",
          quote(do: defaults([:read])),
          quote do
            a2a do
              skill :r, :read do
                hddl_operator(parameters: [:a])
                hddl_operator(parameters: [:b])
              end
            end
          end
        )

      error = first_error(quoted)
      assert error.message =~ "refused_hddl_multiple_operators"
    end

    test "default-projected action with a :term argument warns (no override needed)" do
      quoted =
        resource_quoted(
          "DefaultTerm",
          quote do
            defaults([:read])

            action :snap, :term do
              argument(:state, :term, allow_nil?: false)
              run(fn _i, _c -> {:ok, nil} end)
            end
          end,
          nil
        )

      stderr = warning_messages(quoted)
      assert stderr =~ "default-projected action"
      assert stderr =~ "not JSON-Schema-serializable"
    end

    test "a domain-level skill naming a resource outside the domain is refused" do
      mod = Module.concat(AshA2A.DslLane11Gen, "ForeignResourceDomain")

      quoted =
        quote do
          defmodule unquote(mod) do
            use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

            resources do
              resource(AshA2A.DslMappingCardFixtures.MappedResource)
            end

            a2a do
              skill(:foreign, AshA2A.DslLane11Gen.NotInThisDomain, :read)
            end
          end
        end

      error = assert_raise Spark.Error.DslError, fn -> compile(quoted) end
      assert error.message =~ "not a compiled Ash resource"
    end
  end

  describe "Domain.Info over a real declared domain (PersistConfig)" do
    alias AshA2A.Domain.Info

    test "agent getters" do
      assert Info.agent_name(CardDomain) == "lane11-card"
      assert Info.agent_description(CardDomain) == "Lane 11 card description"
      assert Info.agent_version(CardDomain) == "9.8.7"
      assert Info.agent_provider(CardDomain) == "Lane Eleven Org"
      assert Info.agent_documentation_url(CardDomain) == "https://docs.example.com/lane11"
      assert Info.agent_icon_url(CardDomain) == "https://icons.example.com/lane11.png"
      assert Info.agent(CardDomain).name == "lane11-card"
    end

    test "security getters" do
      assert Enum.map(Info.security_schemes(CardDomain), &{&1.name, &1.kind}) ==
               [token: :bearer, key: :api_key, open: :none]

      assert {:ok, %{kind: :bearer}} = Info.security_scheme(CardDomain, :token)
      assert {:error, :scheme_not_found} = Info.security_scheme(CardDomain, :missing)
      assert Info.security_requirements(CardDomain) == ["token"]
    end

    test "transport getters and card_identity" do
      refute Info.streaming?(CardDomain)
      assert Info.push_notifications?(CardDomain)
      assert Info.base_url(CardDomain) == "https://lane11.example.com"

      assert %{
               name: "lane11-card",
               url: "https://lane11.example.com",
               version: "9.8.7",
               endpoint: "https://lane11.example.com/a2a",
               mount: "/a2a"
             } = Info.card_identity(CardDomain)
    end
  end

  describe "agent card takes identity/security/transport from the domain config" do
    test "name, version, provider, docs, icon, schemes, requirements and capability flags" do
      card = AshA2A.Info.agent_card(CardDomain)

      assert card.name == "lane11-card"
      assert card.description == "Lane 11 card description"
      assert card.version == "9.8.7"
      assert card.url == "https://lane11.example.com"
      assert card.provider == %{organization: "Lane Eleven Org"}
      assert card.documentation_url == "https://docs.example.com/lane11"
      assert card.icon_url == "https://icons.example.com/lane11.png"
      assert card.capabilities.streaming == false
      assert card.capabilities.push_notifications == true

      assert %{"token" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}} =
               Map.take(card.security_schemes, ["token"])

      assert %AshA2A.Protocol.SecurityScheme.APIKey{} = card.security_schemes["key"]
      refute Map.has_key?(card.security_schemes, "open")
      assert card.security == [%{"token" => []}]
    end

    test "explicit opts win over domain config; absent config falls back to defaults" do
      card = AshA2A.Info.agent_card(CardDomain, name: "override", version: "0.0.1")
      assert card.name == "override"
      assert card.version == "0.0.1"

      fallback = AshA2A.Info.agent_card(MappedResource)
      assert fallback.name == "ash_a2a_agent"
      assert fallback.version == "0.1.0"
      assert fallback.url == "http://localhost:4000"
      assert fallback.security_schemes == %{}
    end
  end

  describe "VerifyConfig" do
    test "missing agent.name is refused" do
      quoted =
        domain_quoted(
          "NoName",
          quote do
            agent do
              description "x"
            end

            transport do
              base_url "https://x.example.com"
            end
          end
        )

      error = first_error(quoted)
      assert error.message =~ "agent.name"
    end

    test "invalid security scheme kind is refused" do
      quoted =
        domain_quoted(
          "BadKind",
          quote do
            agent do
              name "n"
            end

            security do
              security_scheme :t, :kerberos
            end

            transport do
              base_url "https://x.example.com"
            end
          end
        )

      assert_raise Spark.Error.DslError, fn -> compile(quoted) end
    end

    test "missing url (no base_url, no agent.url) is a warning, not an error" do
      quoted =
        domain_quoted(
          "NoUrl",
          quote do
            agent do
              name "n"
            end
          end
        )

      stderr = warning_messages(quoted)
      assert stderr =~ "transport.base_url is not set"
    end

    test "duplicate scheme names are refused" do
      quoted =
        domain_quoted(
          "DupScheme",
          quote do
            agent do
              name "n"
              url "https://x.example.com"
            end

            security do
              security_scheme :t, :bearer
              security_scheme :t, :api_key
            end
          end
        )

      error = first_error(quoted)
      assert error.message =~ "duplicate"
    end

    test "requirements naming an undeclared scheme are refused" do
      quoted =
        domain_quoted(
          "UndeclaredReq",
          quote do
            agent do
              name "n"
              url "https://x.example.com"
            end

            security do
              security_scheme :t, :bearer
              requirements ["ghost"]
            end
          end
        )

      error = first_error(quoted)
      assert error.message =~ "references no declared security_scheme"
    end

    test "a malformed base_url is refused" do
      quoted =
        domain_quoted(
          "BadUrl",
          quote do
            agent do
              name "n"
            end

            transport do
              base_url "not a url"
            end
          end
        )

      error = first_error(quoted)
      assert error.message =~ "not a valid absolute http(s) URL"
    end

    test "default_mount without a leading slash is refused" do
      quoted =
        domain_quoted(
          "BadDefaultMount",
          quote do
            agent do
              name "n"
              url "https://x.example.com"
            end

            transport do
              default_mount "a2a"
            end
          end
        )

      error = first_error(quoted)
      assert error.message =~ "must start with"
    end
  end

  describe "VerifyMounts" do
    test "a mounted module that is not an AshA2A.Agent is refused" do
      quoted =
        domain_quoted(
          "NotAnAgent",
          quote do
            agent do
              name "n"
              url "https://x.example.com"
            end

            transport do
              mount agent: Enum, path: "/e", binding: :jsonrpc
            end
          end
        )

      error = first_error(quoted)
      assert error.message =~ "not an AshA2A.Agent"
    end

    test "a mount path without a leading slash is refused" do
      quoted =
        domain_quoted(
          "NoSlash",
          quote do
            agent do
              name "n"
              url "https://x.example.com"
            end

            transport do
              mount agent: AshA2A.DslMappingCardFixtures.Agent, path: "echo", binding: :jsonrpc
            end
          end
        )

      error = first_error(quoted)
      assert error.message =~ "must start with"
    end

    test "overlapping mount path prefixes are refused" do
      quoted =
        domain_quoted(
          "Overlap",
          quote do
            agent do
              name "n"
              url "https://x.example.com"
            end

            transport do
              mount agent: AshA2A.DslMappingCardFixtures.Agent, path: "/a", binding: :jsonrpc
              mount agent: AshA2A.DslMappingCardFixtures.Agent, path: "/a/b", binding: :rest
            end
          end
        )

      error = first_error(quoted)
      assert error.message =~ "is a prefix of"
    end

    test "a :grpc mount draws a warning and valid distinct mounts compile" do
      quoted =
        domain_quoted(
          "GrpcWarn",
          quote do
            agent do
              name "n"
              url "https://x.example.com"
            end

            transport do
              mount agent: AshA2A.DslMappingCardFixtures.Agent, path: "/ok", binding: :jsonrpc
              mount agent: AshA2A.DslMappingCardFixtures.Agent, path: "/grpc", binding: :grpc
            end
          end
        )

      stderr = warning_messages(quoted)
      assert stderr =~ ":grpc binding"
    end
  end
end

# --- SECTION 18: Original test/dsl_verifiers_v1_1_test.exs ---
defmodule AshA2A.DslVerifiersV11Test do
  use ExUnit.Case, async: true

  alias AshA2A.Domain.Verifiers.VerifyExecution

  defp msg({:error, %Spark.Error.DslError{message: m}}), do: m

  describe "events_transport" do
    test "nil, atom, global, via, pid accepted" do
      for v <- [nil, :my_events, MyApp.Events, {:global, :x}, {:via, Registry, {R, 1}}, self()] do
        assert :ok = VerifyExecution.validate(events_transport: v)
      end

      assert :ok = VerifyExecution.validate([])
    end

    test "bad values refused with typed error" do
      for v <- [true, false, "events", 42, [:a], %{}] do
        res = VerifyExecution.validate(events_transport: v)
        assert {:error, %Spark.Error.DslError{path: [:execution, :events_transport]}} = res
        assert msg(res) =~ "invalid `events_transport`"
      end
    end
  end

  describe "cancel_in_flight" do
    test "valid values" do
      for v <- [:refuse, :interrupt, :default, nil] do
        assert :ok = VerifyExecution.validate(cancel_in_flight: v)
      end
    end

    test "invalid values refused" do
      for v <- [:kill, "refuse", true, 1] do
        res = VerifyExecution.validate(cancel_in_flight: v)
        assert msg(res) =~ "invalid `cancel_in_flight`"
      end
    end
  end

  describe "validate_input_modes" do
    test "booleans ok, others refused" do
      assert :ok = VerifyExecution.validate(validate_input_modes: true)
      assert :ok = VerifyExecution.validate(validate_input_modes: false)
      assert msg(VerifyExecution.validate(validate_input_modes: :yes)) =~ "expected a boolean"
      assert msg(VerifyExecution.validate(validate_input_modes: "true")) =~ "expected a boolean"
    end
  end

  describe "user_artifacts" do
    test "execution-keyword form" do
      assert :ok = VerifyExecution.validate(user_artifacts: true)
      assert msg(VerifyExecution.validate(user_artifacts: "yes")) =~ "`user_artifacts`"
    end

    test "domain DSL: good value compiles" do
      quoted =
        quote do
          defmodule AshA2A.Y7Fixtures.GoodArtifactsDomain do
            use Ash.Domain, extensions: [AshA2A.Domain], validate_config_inclusion?: false

            agent do
              name "y7"
              url "https://y7.example.com"
            end

            transport do
              user_artifacts(true)
            end
          end
        end

      assert [{_, _} | _] = Code.compile_quoted(quoted)
    end

    test "domain DSL: non-boolean fails to compile with DslError" do
      quoted =
        quote do
          defmodule AshA2A.Y7Fixtures.BadArtifactsDomain do
            use Ash.Domain, extensions: [AshA2A.Domain], validate_config_inclusion?: false

            agent do
              name "y7"
              url "https://y7.example.com"
            end

            transport do
              user_artifacts("yes")
            end
          end
        end

      error = assert_raise Spark.Error.DslError, fn -> Code.compile_quoted(quoted) end
      assert Exception.message(error) =~ "user_artifacts"
    end
  end

  test "validate!/2 raises the typed error" do
    assert_raise Spark.Error.DslError, ~r/cancel_in_flight/, fn ->
      VerifyExecution.validate!(cancel_in_flight: :nope, events_transport: :ok_name)
    end
  end
end

# --- SECTION 19: Original test/email_brief_test.exs ---
defmodule AshA2A.EmailBriefTest do
  use ExUnit.Case, async: true

  alias AshA2A.Email.Brief

  @d1 "sha256:" <> String.duplicate("1", 64)
  @d2 "sha256:" <> String.duplicate("2", 64)

  defp brief(overrides \\ %{}) do
    Map.merge(
      %{
        title: "Daily",
        date: "2026-11-13",
        sections: [%{heading: "Status", lines: ["all <green>"]}],
        actions: [
          %{n: 2, summary: "Rotate B", action: :rotate, args: %{k: 1}, graph_digest: @d2},
          %{n: 1, summary: "Deploy A", action: :deploy, args: %{}, graph_digest: @d1}
        ]
      },
      overrides
    )
  end

  test "render is byte-identical across calls and action order" do
    b = brief()
    flipped = %{b | actions: Enum.reverse(b.actions)}
    assert Brief.render(b) == Brief.render(b)
    assert Brief.render(b).message_id == Brief.render(flipped).message_id
    assert Brief.brief_digest(b) == Brief.brief_digest(flipped)
  end

  test "message id, headers, and html escaping" do
    r = Brief.render(brief(), domain: "ex.test")
    assert r.message_id =~ ~r/\A<brief\.[0-9a-f]{16}@ex\.test>\z/
    assert {"A2A-Action-1", Brief.reply_token(brief(), 1)} in r.headers
    assert r.html =~ "all &lt;green&gt;"
    assert r.text =~ "[1] Deploy A"
  end

  test "tokens verify; wrong token, other action's token, unknown action fail closed" do
    b = brief()
    t1 = Brief.reply_token(b, 1)
    assert :ok = Brief.verify_reply_token(b, 1, t1)
    assert {:error, :bad_token} = Brief.verify_reply_token(b, 1, t1 <> "0")
    assert {:error, :bad_token} = Brief.verify_reply_token(b, 1, Brief.reply_token(b, 2))
    assert {:error, :bad_token} = Brief.verify_reply_token(b, 1, nil)
    assert {:error, :unknown_action} = Brief.verify_reply_token(b, 9, t1)
  end

  test "content change invalidates old tokens" do
    b = brief()

    changed = %{
      b
      | actions: Enum.map(b.actions, &if(&1.n == 1, do: %{&1 | graph_digest: @d2}, else: &1))
    }

    t = Brief.reply_token(b, 1)
    refute Brief.reply_token(changed, 1) == t
    assert {:error, :bad_token} = Brief.verify_reply_token(changed, 1, t)
  end

  test "malformed graph_digest raises" do
    bad = brief(%{actions: [%{n: 1, summary: "x", action: :a, args: %{}, graph_digest: "nope"}]})
    assert_raise ArgumentError, fn -> Brief.render(bad) end
  end
end

# --- SECTION 20: Original test/email_inbound_test.exs ---
defmodule AshA2A.EmailInboundTest do
  use ExUnit.Case, async: true

  alias AshA2A.Email.Inbound

  @policy %{allowlist: %{"vito@example.com" => "principal:vito"}}

  defp inbound(auth, from \\ "Vito <vito@example.com>") do
    {:ok, i} =
      Inbound.parse(%{
        "from" => from,
        "text" => "Approve 1",
        "in_reply_to" => "<brief.abc@a2a.local>",
        "auth_results" => auth
      })

    i
  end

  @pass %{"dkim" => "pass", "spf" => "pass", "dmarc" => "pass"}

  test "all pass + allowlisted => identity-only principal" do
    assert {:ok, p} = Inbound.verify_sender(inbound(@pass), @policy)

    assert p == %{
             id: "principal:vito",
             address: "vito@example.com",
             authenticated_via: :email,
             authority: :none
           }
  end

  test "in_reply_to angle brackets stripped" do
    assert inbound(@pass).in_reply_to == "brief.abc@a2a.local"
  end

  for k <- ["dkim", "spf", "dmarc"] do
    test "#{k} fail closes" do
      auth = Map.put(@pass, unquote(k), "fail")
      assert {:error, reason} = Inbound.verify_sender(inbound(auth), @policy)
      assert reason == String.to_atom(unquote(k) <> "_fail")
    end

    test "#{k} missing closes" do
      auth = Map.delete(@pass, unquote(k))
      assert {:error, _} = Inbound.verify_sender(inbound(auth), @policy)
    end
  end

  test "unsigned (no verdicts) => :unsigned" do
    assert {:error, :unsigned} = Inbound.verify_sender(inbound(%{}), @policy)
  end

  test "not on allowlist => :sender_not_allowlisted" do
    assert {:error, :sender_not_allowlisted} =
             Inbound.verify_sender(inbound(@pass, "evil@example.com"), @policy)
  end

  test "raw RFC 5322 Authentication-Results header is parsed" do
    raw =
      "From: Vito <vito@example.com>\nTo: a@b.c\nSubject: Re: x\nMessage-ID: <m1@x>\n" <>
        "In-Reply-To: <brief.abc@a2a.local>\n" <>
        "Authentication-Results: mx; dkim=pass; spf=pass; dmarc=fail\n\nApprove 1\n"

    assert {:ok, i} = Inbound.parse(raw)
    assert i.auth_results == %{dkim: :pass, spf: :pass, dmarc: :fail}
    assert {:error, :dmarc_fail} = Inbound.verify_sender(i, @policy)
  end

  test "quote stripping removes quoted lines, attribution tail and signature" do
    body = """
    Approve 1 and 3.

    On Mon, Nov 9, 2026 at 8:00 AM A2A <brief@a2a.local> wrote:
    > [1] Deploy A
    > Reply with the number to approve.
    """

    assert Inbound.reply_text(body) == "Approve 1 and 3."
    assert Inbound.reply_text("Hold 2\n> quoted\n-- \nVito") == "Hold 2"
  end

  test "missing from => error" do
    assert {:error, :missing_from} = Inbound.parse(%{"text" => "x"})
  end
end

# --- SECTION 21: Original test/email_kernel_entry_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Email.KernelEntryTest do
  @moduledoc """
  Real CommandBus path, real InMemory broker, real Item fixture. No doubles.
  Stale-digest handling lives in the plug, not the kernel entry (not applicable here).
  """
  use ExUnit.Case, async: false

  alias AshA2A.Authority.Broker.InMemory
  alias AshA2A.Authority.Grant
  alias AshA2A.Email.KernelEntry
  alias AshA2A.Identity
  alias AshA2A.Test.Fixture.Item

  @capability "AshA2A.Test.Fixture.Item.create"

  setup do
    Application.put_env(:ash_a2a, :receipt_commit_retry_delays_ms, [1, 1])

    suffix = System.unique_integer([:positive])
    store = Module.concat(__MODULE__, "Store#{suffix}")
    broker = Module.concat(__MODULE__, "Broker#{suffix}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: store})
    start_supervised!(Supervisor.child_spec({InMemory, name: broker}, id: broker))

    prior_policy = Application.get_env(:ash_a2a, :authority_policy)
    prior_broker = Application.get_env(:ash_a2a, :authority_broker)
    Application.put_env(:ash_a2a, :authority_policy, :broker)
    Application.put_env(:ash_a2a, :authority_broker, {InMemory, name: broker})

    on_exit(fn ->
      Application.delete_env(:ash_a2a, :receipt_commit_retry_delays_ms)
      restore(:authority_policy, prior_policy)
      restore(:authority_broker, prior_broker)
    end)

    %{bus_opts: [store_opts: [name: store]]}
  end

  defp restore(key, nil), do: Application.delete_env(:ash_a2a, key)
  defp restore(key, value), do: Application.put_env(:ash_a2a, key, value)

  defp principal(id),
    do: %{id: id, address: "#{id}@example.com", authenticated_via: :email, authority: :none}

  test "granted principal dispatches through the CommandBus", %{bus_opts: bus_opts} do
    {:ok, _} = Grant.grant(Identity.principal("mail-granted"), @capability)

    assert {:ok, receipt} =
             KernelEntry.run(@capability, %{"label" => "widget"}, Item, principal("mail-granted"),
               bus_opts: bus_opts
             )

    assert receipt.status == :completed
    assert receipt.consequence == :change
  end

  test "principal without a grant is refused with a typed code, nothing dispatched", %{
    bus_opts: bus_opts
  } do
    assert {:error, %{code: :email_no_live_grant}} =
             KernelEntry.run(@capability, %{"label" => "widget"}, Item, principal("mail-nogrant"),
               bus_opts: bus_opts
             )

    assert :email_no_live_grant in Map.keys(AshA2A.Semantic.Refusal.mapping())
  end

  test "revoked grant is refused", %{bus_opts: bus_opts} do
    subject = Identity.principal("mail-revoked")
    {:ok, _} = Grant.grant(subject, @capability)
    :ok = Grant.revoke(subject, @capability)

    assert {:error, %{code: :email_no_live_grant}} =
             KernelEntry.run(@capability, %{"label" => "x"}, Item, principal("mail-revoked"),
               bus_opts: bus_opts
             )
  end

  test "unknown skill is refused capability_not_found", %{bus_opts: bus_opts} do
    assert {:error, %{code: :capability_not_found}} =
             KernelEntry.run("nope", %{}, Item, principal("mail-granted"), bus_opts: bus_opts)
  end
end

# --- SECTION 22: Original test/email_plug_test.exs ---
defmodule AshA2A.EmailPlugTest do
  @moduledoc """
  Plug.Test over AshA2A.Email.Plug with real Brief, Inbound, ReplyIntent.

  Named exception: dispatch and reply_sender are hand-written real function fakes
  recording into an Agent (external SMTP and the governed agent are infeasible in-process).
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias AshA2A.Email.Brief
  alias AshA2A.Email.Plug, as: EmailPlug

  @digest "sha256:" <> String.duplicate("a", 64)
  @sender "approver@example.test"

  setup do
    {:ok, rec} = Agent.start_link(fn -> %{dispatched: [], replies: []} end)
    on_exit(fn -> if Process.alive?(rec), do: Agent.stop(rec) end)
    {:ok, rec: rec}
  end

  # ---- adapter section -------------------------------------------------------

  defp opts(rec, over \\ []) do
    b = brief()
    mid = bare_id(Brief.render(b).message_id)

    base = [
      policy: %{allowlist: %{@sender => "principal:approver"}},
      brief_lookup: fn
        ^mid -> {:ok, b, %{1 => @digest, 2 => @digest, 3 => @digest}}
        _ -> :error
      end,
      dispatch: fn principal, action ->
        Agent.update(rec, &Map.update!(&1, :dispatched, fn l -> l ++ [{principal, action}] end))
        {:ok, :done}
      end,
      reply_sender: fn to, subject, text ->
        Agent.update(rec, &Map.update!(&1, :replies, fn l -> l ++ [{to, subject, text}] end))
        :ok
      end
    ]

    EmailPlug.init(Keyword.merge(base, over))
  end

  defp brief do
    %{
      title: "Daily",
      date: "2026-11-13",
      sections: [],
      actions: [
        %{n: 1, summary: "Deploy A", action: :deploy, args: %{svc: "a"}, graph_digest: @digest},
        %{n: 2, summary: "Rotate B", action: :rotate, args: %{}, graph_digest: @digest},
        %{n: 3, summary: "Scale C", action: :scale, args: %{}, graph_digest: @digest}
      ]
    }
  end

  defp inbound_conn(b, text, dkim) do
    mid = bare_id(Brief.render(b).message_id)

    params = %{
      "from" => @sender,
      "in_reply_to" => mid,
      "text" => text,
      "subject" => "Re: brief",
      "auth_results" => %{"dkim" => dkim, "spf" => "pass", "dmarc" => "pass"},
      "reply_tokens" =>
        Map.new([1, 2, 3], fn n -> {Integer.to_string(n), Brief.reply_token(b, n)} end)
    }

    conn(:post, "/v1/email:ingest", params)
  end

  defp bare_id(id), do: id |> String.trim_leading("<") |> String.trim_trailing(">")

  defp tamper(token) when is_binary(token) do
    last = String.last(token)
    String.slice(token, 0..-2//1) <> if(last == "0", do: "1", else: "0")
  end

  # ---- helpers ---------------------------------------------------------------

  defp state(rec), do: Agent.get(rec, & &1)
  defp run(conn, opts), do: EmailPlug.call(conn, opts)

  # ---- cases -----------------------------------------------------------------

  test "bad DKIM => 401 and no dispatch", %{rec: rec} do
    conn = run(inbound_conn(brief(), "Approve 1 and 3. Hold 2.", "fail"), opts(rec))

    assert conn.status == 401
    assert state(rec).dispatched == []
  end

  test "approve 1 and 3, hold 2 => exactly two dispatched under sender principal", %{rec: rec} do
    conn =
      run(
        inbound_conn(brief(), "Approve 1 and 3. Hold 2 until I talk to Larson.", "pass"),
        opts(rec)
      )

    assert conn.status == 200, conn.resp_body
    dispatched = state(rec).dispatched
    assert Enum.map(dispatched, fn {_, a} -> a.n end) == [1, 3]

    assert Enum.all?(dispatched, fn {p, _} ->
             p.id == "principal:approver" and p.authority == :none
           end)

    standings =
      Jason.decode!(conn.resp_body)["results"] |> Map.new(&{&1["action"], &1["standing"]})

    assert standings == %{1 => "dispatched", 2 => "held", 3 => "dispatched"}
    assert [{@sender, _, _}] = state(rec).replies
  end

  test "stale graph digest => 409 and reconfirm email, no dispatch", %{rec: rec} do
    b = brief()
    mid = bare_id(Brief.render(b).message_id)
    stale = "sha256:" <> String.duplicate("b", 64)

    o =
      opts(rec,
        brief_lookup: fn ^mid -> {:ok, b, %{1 => stale, 2 => @digest, 3 => @digest}} end
      )

    conn = run(inbound_conn(b, "Approve 1 and 3. Hold 2.", "pass"), o)

    assert conn.status == 409
    st = state(rec)
    assert st.dispatched == []
    assert length(st.replies) == 1
  end

  test "unknown in_reply_to => 404, no dispatch", %{rec: rec} do
    c = inbound_conn(brief(), "Approve 1", "pass")
    params = Map.put(c.body_params, "in_reply_to", "no-such-brief@test")
    conn = run(conn(:post, "/v1/email:ingest", params), opts(rec))

    assert conn.status == 404
    assert state(rec).dispatched == []
  end

  test "tampered token => 403, no dispatch", %{rec: rec} do
    c = inbound_conn(brief(), "Approve 1 and 3.", "pass")
    params = update_in(c.body_params, ["reply_tokens", "1"], &tamper/1)
    conn = run(conn(:post, "/v1/email:ingest", params), opts(rec))

    assert conn.status == 403
    assert state(rec).dispatched == []
  end

  test "default dispatch refuses unresolvable actions", %{rec: rec} do
    o = opts(rec, dispatch: nil)
    conn = run(inbound_conn(brief(), "Approve 1.", "pass"), o)

    assert conn.status == 200, conn.resp_body
    [r] = Jason.decode!(conn.resp_body)["results"]
    assert r["standing"] == "refused"
    assert r["reason"] =~ "unresolvable"
  end
end
