# Lane V28 fixture modules live at TOP LEVEL of this file (never nested inside
# the test module: Elixir nests dotted module names under the enclosing
# module, which breaks `use Ash.Resource`'s `AshA2A` extension resolution).

defmodule AshA2A.Test.Fixture.V28ChallengeNote do
  @moduledoc """
  Lane-V28-owned fixture resource for
  `test/ash_a2a_v1_auth_challenge_test.exs`'s end-to-end threading court.
  Modeled on `AshA2A.Test.Fixture.TenantActorNote` but defined inline with
  UNIQUE module names so the court can start its own agent under its own
  registration name without colliding with the concurrently-running
  `test/ash_a2a_plug_tenant_actor_test.exs` (which registers
  `AshA2A.Test.Fixture.TenantActorNoteAgent` by module name).

  Real, load-bearing behavior exercised: the created record's `created_by`
  is force-set from the REAL `context.actor` by a real `Ash.Resource.Change`
  (never accepted as create input), behind a real `actor_present()`
  `Ash.Policy.Authorizer` policy -- so the only way the court's `created_by`
  assertion can pass is the verified HTTP credential really threading
  through the full real pipeline.
  """

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.V28ChallengeNoteDomain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:body, :string, public?: true, allow_nil?: false)

    # Never accepted as create input -- populated only from the real verified
    # `context.actor` by the change below.
    attribute(:created_by, :string, public?: true, allow_nil?: true)
  end

  changes do
    change(fn changeset, context ->
      actor_id =
        case context.actor do
          %{id: id} -> id
          %{"id" => id} -> id
          _other -> nil
        end

      Ash.Changeset.force_change_attribute(changeset, :created_by, actor_id)
    end)
  end

  policies do
    policy(always()) do
      authorize_if(actor_present())
    end
  end

  actions do
    defaults([:read, create: [:body]])
  end

  a2a do
    skill(:create_note, :create)
  end
end

defmodule AshA2A.Test.Fixture.V28ChallengeNoteDomain do
  @moduledoc """
  Real fixture domain for `AshA2A.Test.Fixture.V28ChallengeNote`.
  """

  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2A.Test.Fixture.V28ChallengeNote)
  end
end

defmodule AshA2A.Test.Fixture.V28ChallengeNoteAgent do
  @moduledoc """
  Real `AshA2A.Protocol.Agent` GenServer over `AshA2A.Test.Fixture.V28ChallengeNote`.
  `AshA2A.Protocol.Agent.start_link/1` registers the process under its own
  module name by default, so this module name doubles as the unique
  registration name the court's real `AshA2A.Protocol.Plug` fronts (no
  collision with any concurrently-running lane's agent registration).
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.V28ChallengeNote,
    name: "v28_auth_challenge_agent"
end

defmodule AshA2A.Protocol.V1AuthChallengeConformanceTest do
  @moduledoc """
  Lane V28: orthogonal end-to-end conformance court for wire authentication
  per A2A v1.0 security semantics (§ "Authentication and Authorization" /
  § Error Handling: a server "MUST reject requests with invalid or missing
  authentication credentials" and "SHOULD include authentication challenge
  information in the error response") plus RFC 7235 challenge syntax, run
  against the REAL `AshA2A.Protocol.Plug.Auth` middleware.

  Chicago-style throughout: real `Plug.Test` conns, the real
  `AshA2A.Protocol.Plug.Auth.call/2` (scheme extraction, OR-of-AND security
  requirement evaluation, verify callback invocation, WWW-Authenticate
  challenge generation, `conn.private[:a2a][:auth]` contract), a real
  supervised `AshA2A.Protocol.Agent` GenServer behind the real
  `AshA2A.Protocol.Plug`, real verify callbacks defined in this file, and a
  real Ash resource (`AshA2A.Test.Fixture.V28ChallengeNote`) whose created
  record's `created_by` is the end-state asserted on. No
  Mock/mox/patch/monkeypatch anywhere in this file.

  Where the spec/RFC and the real implementation disagree, this court PINS
  REALITY (never the spec) and the pinning test carries a `# GAP:` comment;
  the gaps are catalogued in the lane's report. No `lib/` edits.
  """

  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias AshA2A.Protocol.SecurityScheme.{APIKey, HTTPAuth, MutualTLS, OAuth2, OpenIDConnect}

  @bearer %HTTPAuth{scheme: "bearer"}
  @basic %HTTPAuth{scheme: "basic"}

  setup do
    # Real supervised agent GenServer, registered under its own unique module
    # name, so the court's real AshA2A.Protocol.Plug can front it.
    {:ok, _pid} = start_supervised(AshA2A.Test.Fixture.V28ChallengeNoteAgent)
    :ok
  end

  # -- Real verify callback (in-file, no mocks) ------------------------------

  # Real verify callback over every scheme kind this court exercises. The
  # clause heads double as extraction-shape courts: they only match when
  # `AshA2A.Protocol.Plug.Auth` really extracted the credential into the
  # documented shape (String.t() for bearer/oauth2/oidc/api-key, {username,
  # password} for Basic), so a broken extraction surfaces as a 401 in the
  # test, never as a passing assertion.
  defp verify("bearer_auth", "v28-bearer-token", _conn),
    do: {:ok, %{id: "v28-user-1", tenant: "acme"}}

  defp verify("basic_auth", {"v28-alice", "v28-basic-secret"}, _conn),
    do: {:ok, %{id: "v28-basic-user", tenant: "acme"}}

  defp verify("api_key", "v28-api-key-1", _conn),
    do: {:ok, %{id: "v28-api-user", tenant: "acme"}}

  defp verify("oauth2_scheme", "v28-oauth2-token", _conn),
    do: {:ok, %{id: "v28-oauth2-user", tenant: "acme"}}

  defp verify("oidc_scheme", "v28-oidc-token", _conn),
    do: {:ok, %{id: "v28-oidc-user", tenant: "acme"}}

  defp verify(_scheme, _credential, _conn), do: {:error, "invalid credentials"}

  # -- Real pipelines ---------------------------------------------------------

  # Auth-middleware-only pipeline: the real `AshA2A.Protocol.Plug.Auth.call/2`
  # with real init/2 validation. Returns the conn so courts can assert on the
  # real 401 response AND on `conn.private[:a2a][:auth]`.
  defp run_auth(conn, schemes, security \\ nil, realm \\ "a2a", verify \\ &verify/3) do
    opts =
      AshA2A.Protocol.Plug.Auth.init(
        schemes: schemes,
        verify: verify,
        security: security,
        realm: realm
      )

    AshA2A.Protocol.Plug.Auth.call(conn, opts)
  end

  # Full real pipeline: auth middleware + real `AshA2A.Protocol.Plug` fronting
  # a real supervised agent, exactly as `AshA2A.Protocol.Plug.Auth`'s own
  # moduledoc prescribes.
  defp run_full_pipeline(conn) do
    auth_opts =
      AshA2A.Protocol.Plug.Auth.init(
        schemes: %{"bearer_auth" => @bearer},
        verify: &verify/3
      )

    plug_opts =
      AshA2A.Protocol.Plug.init(
        agent: AshA2A.Test.Fixture.V28ChallengeNoteAgent,
        base_url: "http://localhost:4000/a2a"
      )

    conn
    |> AshA2A.Protocol.Plug.Auth.call(auth_opts)
    |> then(fn conn ->
      if conn.halted, do: conn, else: AshA2A.Protocol.Plug.call(conn, plug_opts)
    end)
  end

  defp create_note_request_body(body) do
    message = %{
      AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(%{"body" => body})])
      | metadata: %{"skill" => "create_note"}
    }

    {:ok, message_json} = AshA2A.Protocol.JSON.encode(message)

    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => "req-1",
      "method" => "message/send",
      "params" => %{"message" => message_json}
    })
  end

  defp bearer_post(token, body) do
    conn =
      conn(:post, "/", body)
      |> put_req_header("content-type", "application/json")

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    run_full_pipeline(conn)
  end

  defp assert_completed_task_with_data(conn) do
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert %{"result" => %{"task" => task_json}} = body

    assert %{"status" => %{"state" => "TASK_STATE_COMPLETED"}, "artifacts" => [artifact]} =
             task_json

    assert %{"parts" => [%{"data" => data}]} = artifact
    data
  end

  # -- (a) Bearer scheme, no Authorization header -----------------------------

  test "bearer scheme, no Authorization header: 401 with exact Bearer WWW-Authenticate challenge, reason never leaked" do
    conn = run_auth(conn(:post, "/", "x"), %{"bearer_auth" => @bearer})

    assert conn.halted
    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") == [~s(Bearer realm="a2a")]

    # Real body: generic error only -- the verify callback's reason string is
    # never present (and never sent on the wire).
    assert Jason.decode!(conn.resp_body) == %{"error" => "Unauthorized"}
  end

  test "bearer scheme: custom realm is pinned verbatim into the challenge" do
    conn = run_auth(conn(:post, "/", "x"), %{"bearer_auth" => @bearer}, nil, "v28-corp")

    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") == [~s(Bearer realm="v28-corp")]
  end

  # RFC 7235 section 2.1: "the authentication scheme is case-insensitive".
  # Formerly a GAP PIN (the literal "Bearer " prefix match rejected "bearer
  # x"); the case-insensitive scheme comparison landed in
  # protocol/plug/auth.ex (authorization_scheme_credential/1), so this is now
  # a positive pin.
  test "RFC 7235 case-insensitivity: lowercase 'bearer' scheme prefix authenticates" do
    conn =
      conn(:post, "/", "x")
      |> put_req_header("authorization", "bearer v28-bearer-token")
      |> run_auth(%{"bearer_auth" => @bearer})

    refute conn.halted

    assert AshA2A.Protocol.Plug.Auth.get_identity(conn) == %{
             scheme: "bearer_auth",
             identity: %{id: "v28-user-1", tenant: "acme"}
           }
  end

  test "RFC 7235 case-insensitivity: mixed-case 'BeArEr' scheme prefix authenticates too" do
    conn =
      conn(:post, "/", "x")
      |> put_req_header("authorization", "BeArEr v28-bearer-token")
      |> run_auth(%{"bearer_auth" => @bearer})

    refute conn.halted

    assert AshA2A.Protocol.Plug.Auth.get_identity(conn) == %{
             scheme: "bearer_auth",
             identity: %{id: "v28-user-1", tenant: "acme"}
           }
  end

  test "unknown scheme label still 401s: only 'bearer'/'basic' (any case) are extracted" do
    conn =
      conn(:post, "/", "x")
      |> put_req_header("authorization", "Xauth v28-bearer-token")
      |> run_auth(%{"bearer_auth" => @bearer})

    assert conn.halted
    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") == [~s(Bearer realm="a2a")]
  end

  # -- (b) Basic scheme --------------------------------------------------------

  test "basic scheme, no Authorization header: 401 with exact Basic challenge" do
    conn = run_auth(conn(:post, "/", "x"), %{"basic_auth" => @basic})

    assert conn.halted
    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") == [~s(Basic realm="a2a")]
  end

  test "basic scheme: real base64 decoding threads a real {username, password} tuple to verify/3, identity lands in conn.private[:a2a][:auth]" do
    encoded = Base.encode64("v28-alice:v28-basic-secret")

    conn =
      conn(:post, "/", "x")
      |> put_req_header("authorization", "Basic #{encoded}")
      |> run_auth(%{"basic_auth" => @basic})

    refute conn.halted

    # The verify callback clause above only matches the DECODED tuple, so a
    # pass here is the real end-state proof of real base64 decode + split.
    assert AshA2A.Protocol.Plug.Auth.get_identity(conn) == %{
             scheme: "basic_auth",
             identity: %{id: "v28-basic-user", tenant: "acme"}
           }
  end

  # Formerly a GAP PIN (the literal "Basic " prefix match rejected "basic
  # x"); the case-insensitive scheme comparison landed in
  # protocol/plug/auth.ex, so this is now a positive pin.
  test "RFC 7235 case-insensitivity: lowercase 'basic' scheme prefix authenticates" do
    encoded = Base.encode64("v28-alice:v28-basic-secret")

    conn =
      conn(:post, "/", "x")
      |> put_req_header("authorization", "basic #{encoded}")
      |> run_auth(%{"basic_auth" => @basic})

    refute conn.halted

    # The verify callback clause above only matches the DECODED tuple, so a
    # pass here is the real end-state proof that the lowercase scheme label
    # still threaded real base64 decode + split.
    assert AshA2A.Protocol.Plug.Auth.get_identity(conn) == %{
             scheme: "basic_auth",
             identity: %{id: "v28-basic-user", tenant: "acme"}
           }
  end

  test "basic scheme: malformed base64 fails closed with 401" do
    conn =
      conn(:post, "/", "x")
      |> put_req_header("authorization", "Basic !!!not-base64!!!")
      |> run_auth(%{"basic_auth" => @basic})

    assert conn.halted
    assert conn.status == 401
  end

  # -- (c) OAuth2 / OpenID Connect schemes -> Bearer challenges ----------------

  test "oauth2-only scheme: 401 carries a Bearer challenge per the real implementation" do
    oauth2 = %OAuth2{flows: %{}}

    conn = run_auth(conn(:post, "/", "x"), %{"oauth2_scheme" => oauth2})

    assert conn.halted
    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") == [~s(Bearer realm="a2a")]
  end

  test "openid-connect-only scheme: 401 carries a Bearer challenge per the real implementation" do
    oidc = %OpenIDConnect{
      open_id_connect_url: "https://accounts.example.com/.well-known/openid-configuration"
    }

    conn = run_auth(conn(:post, "/", "x"), %{"oidc_scheme" => oidc})

    assert conn.halted
    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") == [~s(Bearer realm="a2a")]
  end

  test "oauth2 and oidc schemes together: real bearer tokens authenticate through both" do
    oauth2 = %OAuth2{flows: %{}}

    oidc = %OpenIDConnect{
      open_id_connect_url: "https://accounts.example.com/.well-known/openid-configuration"
    }

    conn =
      conn(:post, "/", "x")
      |> put_req_header("authorization", "Bearer v28-oauth2-token")
      |> run_auth(%{"oauth2_scheme" => oauth2, "oidc_scheme" => oidc})

    refute conn.halted

    # Default security derivation: each scheme becomes its own SINGLE-scheme
    # OR alternative, and the first satisfied alternative wins -- so the
    # pinned identity is exactly the single-leg shape %{scheme, identity}
    # with NO :identities key (that key only appears under a real
    # multi-scheme AND requirement, see the AND court below).
    assert AshA2A.Protocol.Plug.Auth.get_identity(conn) == %{
             scheme: "oauth2_scheme",
             identity: %{id: "v28-oauth2-user", tenant: "acme"}
           }
  end

  # -- (d) API-key and mTLS schemes: no WWW-Authenticate at all ----------------

  test "api-key (header) scheme, missing key: 401 with NO WWW-Authenticate header -- pinned reality" do
    api_key = %APIKey{in: "header", name: "X-V28-Key"}

    conn = run_auth(conn(:post, "/", "x"), %{"api_key" => api_key})

    assert conn.halted
    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") == []
    assert Jason.decode!(conn.resp_body) == %{"error" => "Unauthorized"}
  end

  test "api-key (header) scheme: key sent case-insensitively by header name authenticates" do
    api_key = %APIKey{in: "header", name: "X-V28-Key"}

    conn =
      conn(:post, "/", "x")
      |> put_req_header("x-v28-key", "v28-api-key-1")
      |> run_auth(%{"api_key" => api_key})

    refute conn.halted

    assert AshA2A.Protocol.Plug.Auth.get_identity(conn) == %{
             scheme: "api_key",
             identity: %{id: "v28-api-user", tenant: "acme"}
           }
  end

  test "mTLS scheme: credential extraction is unsupported, fails closed 401 with no challenge -- pinned reality" do
    conn = run_auth(conn(:post, "/", "x"), %{"mtls" => %MutualTLS{}})

    assert conn.halted
    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") == []
  end

  # -- (e) OR-of-AND security requirements --------------------------------------

  test "OR alternatives: scheme A credentials pass, scheme B credentials pass, neither is a real 401" do
    schemes = %{"bearer_auth" => @bearer, "basic_auth" => @basic}
    security = [%{"bearer_auth" => []}, %{"basic_auth" => []}]

    # Alternative 1 (Bearer) satisfied.
    conn_a =
      conn(:post, "/", "x")
      |> put_req_header("authorization", "Bearer v28-bearer-token")
      |> run_auth(schemes, security)

    refute conn_a.halted
    assert %{scheme: "bearer_auth"} = AshA2A.Protocol.Plug.Auth.get_identity(conn_a)

    # Alternative 2 (Basic) satisfied -- without the first alternative's
    # credential present at all.
    conn_b =
      conn(:post, "/", "x")
      |> put_req_header("authorization", "Basic #{Base.encode64("v28-alice:v28-basic-secret")}")
      |> run_auth(schemes, security)

    refute conn_b.halted
    assert %{scheme: "basic_auth"} = AshA2A.Protocol.Plug.Auth.get_identity(conn_b)

    # Neither -> real 401. RFC 7235 section 3.1: the 401 carries a challenge
    # for EACH applicable scheme — the former single-challenge behavior was a
    # put_resp_header/3 replacement bug, fixed in protocol/plug/auth.ex
    # (separate www-authenticate headers are appended per scheme).
    neither =
      conn(:post, "/", "x")
      |> run_auth(schemes, security)

    assert neither.halted
    assert neither.status == 401

    challenges = get_resp_header(neither, "www-authenticate")
    assert length(challenges) == 2
    assert hd(challenges) in [~s(Bearer realm="a2a"), ~s(Basic realm="a2a")]
  end

  test "AND requirement: only the full credential set passes; any subset fails 401 -- AND requirements are really supported" do
    # One alternative whose map requires BOTH schemes (AND). The two legs use
    # distinct credential carriers (Authorization header + API-key header),
    # because a second Authorization header is not representable in a single
    # request -- see the two-HTTP-leg gap court below.
    schemes = %{"and_bearer" => @bearer, "and_api_key" => %APIKey{in: "header", name: "X-V28-Key"}}
    security = [%{"and_bearer" => [], "and_api_key" => []}]

    verify = fn
      "and_bearer", "v28-bearer-token", _conn -> {:ok, %{id: "v28-and-user", tenant: "acme"}}
      "and_api_key", "v28-api-key-1", _conn -> {:ok, %{id: "v28-and-user", tenant: "acme"}}
      _, _, _ -> {:error, "invalid credentials"}
    end

    # Both present: passes, and the real identity records every AND leg in
    # `identities` plus the first-listed leg as the primary scheme/identity.
    both =
      conn(:post, "/", "x")
      |> put_req_header("authorization", "Bearer v28-bearer-token")
      |> put_req_header("x-v28-key", "v28-api-key-1")
      |> run_auth(schemes, security, "a2a", verify)

    refute both.halted

    # Reality pin: the primary scheme/identity is `hd(Map.keys(requirements))`
    # -- the first key the runtime iterates, NOT a documented precedence. Both
    # AND legs are really present in `identities`.
    assert %{scheme: primary, identity: %{id: "v28-and-user"}, identities: identities} =
             AshA2A.Protocol.Plug.Auth.get_identity(both)

    assert primary in ["and_bearer", "and_api_key"]

    assert identities == %{
             "and_bearer" => %{id: "v28-and-user", tenant: "acme"},
             "and_api_key" => %{id: "v28-and-user", tenant: "acme"}
           }

    # AND leg 1 only (missing API key): real 401.
    bearer_only =
      conn(:post, "/", "x")
      |> put_req_header("authorization", "Bearer v28-bearer-token")
      |> run_auth(schemes, security, "a2a", verify)

    assert bearer_only.halted
    assert bearer_only.status == 401

    # AND leg 2 only (missing Bearer): real 401.
    key_only =
      conn(:post, "/", "x")
      |> put_req_header("x-v28-key", "v28-api-key-1")
      |> run_auth(schemes, security, "a2a", verify)

    assert key_only.halted
    assert key_only.status == 401
  end

  test "AND requirement over two HTTP-scheme legs is unsatisfiable by any single request: both legs read the one Authorization header" do
    # GAP (expressiveness): two `http` schemes in one AND requirement both
    # extract from the same `authorization` header. The first leg's scheme
    # must match the header's prefix, so an AND of Bearer+Basic can never be
    # satisfied by any single request. Pinned as a real 401, not a crash.
    schemes = %{"and_bearer" => @bearer, "and_basic" => @basic}
    security = [%{"and_bearer" => [], "and_basic" => []}]

    conn =
      conn(:post, "/", "x")
      |> put_req_header("authorization", "Bearer v28-bearer-token")
      |> run_auth(schemes, security)

    assert conn.halted
    assert conn.status == 401
  end

  test "security referencing an unknown scheme is refused at init/2 (real validation)" do
    assert_raise ArgumentError,
                 ~r/unknown scheme/,
                 fn ->
                   AshA2A.Protocol.Plug.Auth.init(
                     schemes: %{"bearer_auth" => @bearer},
                     verify: &verify/3,
                     security: [%{"nope" => []}]
                   )
                 end
  end

  # -- (f) valid credential threads end to end into the real Ash action --------

  test "valid Bearer credential threads into the real pipeline: identity lands in conn.private[:a2a][:auth] and the real Ash create records created_by from the real actor" do
    AshA2A.Test.AuthorityGrantCase.grant!([
      {%{id: "v28-user-1", tenant: "acme"}, AshA2A.Test.Fixture.V28ChallengeNote, ["create_note"]}
    ])

    conn = bearer_post("v28-bearer-token", create_note_request_body("v28 note"))

    refute conn.halted
    assert conn.status == 200

    # The conn.private[:a2a][:auth] contract holds after the FULL pipeline.
    assert AshA2A.Protocol.Plug.Auth.get_identity(conn) == %{
             scheme: "bearer_auth",
             identity: %{id: "v28-user-1", tenant: "acme"}
           }

    # Real end-state: the record the real Ash action really created carries
    # created_by == the verified identity's id -- threaded by the real
    # Plug.Auth -> Protocol.Plug -> Agent.__dispatch__ -> ContextResolver
    # chain, not asserted via any interaction.
    data = assert_completed_task_with_data(conn)
    assert data["created_by"] == "v28-user-1"
    assert data["body"] == "v28 note"
  end

  test "valid credential on the wire but a verify rejection: 401 with the generic body, no reason leak" do
    conn =
      conn(:post, "/", "x")
      |> put_req_header("authorization", "Bearer v28-wrong-token")
      |> run_auth(%{"bearer_auth" => @bearer})

    assert conn.halted
    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") == [~s(Bearer realm="a2a")]
    assert Jason.decode!(conn.resp_body) == %{"error" => "Unauthorized"}
  end

  # -- (g) verify callback raising ---------------------------------------------

  test "a raising verify callback fails CLOSED as 401 — exception detail never reaches the caller" do
    # Formerly a GAP PIN (the raise escaped call/2 as a 500); the fail-closed
    # rescue landed in protocol/plug/auth.ex (safe_verify/4). The caller sees
    # the generic 401; the exception detail goes nowhere on the wire.
    verify_boom = fn _scheme, _credential, _conn -> raise "v28 verify boom" end

    # The credential must really EXTRACT first (a well-formed Bearer header)
    # so the raise happens inside the real verify invocation, not at the
    # earlier :missing short-circuit.
    conn =
      conn(:post, "/", "x")
      |> put_req_header("authorization", "Bearer v28-any-token")

    opts =
      AshA2A.Protocol.Plug.Auth.init(
        schemes: %{"bearer_auth" => @bearer},
        verify: verify_boom
      )

    conn = AshA2A.Protocol.Plug.Auth.call(conn, opts)

    assert conn.halted
    assert conn.status == 401
    refute conn.resp_body =~ "v28 verify boom"
  end

  # -- Exempt paths --------------------------------------------------------------

  test "default exempt path: GET /.well-known/agent-card.json bypasses authentication entirely" do
    conn =
      conn(:get, "/.well-known/agent-card.json")
      |> run_auth(%{"bearer_auth" => @bearer})

    refute conn.halted
    # The exempt contract also means no identity is stored for the request.
    assert AshA2A.Protocol.Plug.Auth.get_identity(conn) == nil
  end

  test "custom exempt_paths really re-scope the bypass: the exempted path passes through, other paths still 401" do
    opts =
      AshA2A.Protocol.Plug.Auth.init(
        schemes: %{"bearer_auth" => @bearer},
        verify: &verify/3,
        exempt_paths: [["public"]]
      )

    exempted =
      conn(:get, "/public")
      |> AshA2A.Protocol.Plug.Auth.call(opts)

    refute exempted.halted

    nonexempt =
      conn(:get, "/private")
      |> AshA2A.Protocol.Plug.Auth.call(opts)

    assert nonexempt.halted
    assert nonexempt.status == 401
  end
end
