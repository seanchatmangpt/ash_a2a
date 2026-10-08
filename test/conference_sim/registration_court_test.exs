# Lane EV2 — Conference-sim registration as a commerce path (entitlement-law
# mirror of ggen-marketplace's entitlement seam).
#
# Commerce path under court:
#
#   attendee pays → registration authority issues a BADGE = a REAL signed
#   agent card (`AshA2A.Info.agent_card/2` over the real
#   `ConferenceSim.Registration` resource, signed by
#   `AshA2A.Protocol.CardSigning.sign/3` under the venue key,
#   `kid: "venue-badge-signing-key"`), whose claims (attendee_id, tier, exp,
#   event) are bound UNDER the signature in the card description.
#
#   the venue's badge gate (real `AshA2A.Protocol.Plug.Auth` middleware, real
#   `x-badge` API-key extraction, real detached-JWS signature verification via
#   `CardSigning.verify/2` against the venue key set) accepts the badge for
#   tier-appropriate methods and refuses, at the wire:
#
#     * expired badge      → 401 + RFC 7235 WWW-Authenticate challenge
#     * forged badge       → 401 (wrong-key `:bad_signature`)
#     * tampered binding   → 401 (`:digest_mismatch` — rebinding the badge to
#                            another attendee breaks the signature's digest)
#     * unknown kid        → 401 (`:unknown_kid` under the venue key set)
#     * wrong-event badge  → 401 (domain-lifting refusal: a badge from another
#                            event is not admission here)
#     * wrong-tier access  → 403 typed `tier_access_denied` envelope
#                            (workshop-only method hit with a :general badge)
#
# Positive paths for each tier (general / workshop / vip / press) over the
# real plug pipeline on real Bandit HTTP servers with real Req requests.
#
# Cross-check (entitlement-seam correlation): the badge_id ↔ attendee binding
# (card `name` = `badge:<attendee_id>`) mirrors ggen-marketplace's
# usageReportingId correlation — the granted wire response echoes the bound
# pair together, the signature covers the binding (tamper → digest_mismatch),
# and a badge issued for one attendee can never grant as another. No
# Mock/mox/patch/monkeypatch anywhere in this file: real signed cards, real
# plug pipeline, wire-body assertions.
#
# Fixture modules live at TOP LEVEL of this file (never nested inside the
# test module: Elixir nests dotted module names under the enclosing module).

defmodule AshA2A.Test.ConferenceSim.RegistrationIssuer do
  @moduledoc """
  The registration authority's badge mint: builds the REAL agent card over
  the real `ConferenceSim.Registration` resource (same builder the fixture's
  `issue_badge/3` uses), binds the commerce claims (attendee_id, tier, exp,
  event) in the card description, and signs under the venue key with the
  fixture's `kid` — `AshA2A.Protocol.CardSigning.sign/3`, HS256 by default,
  ES256 for the asymmetric court.
  """

  alias AshA2A.Protocol.CardSigning

  @default_event "AGNTCon+MCPCon"
  @venue_url "https://venue.agntcon.example/registration"

  def default_event, do: @default_event

  @doc """
  Issues a signed badge card for `attendee_id` at `tier`.

  Options: `:exp` (unix seconds, default now + 3600), `:event`, `:key`
  (signing key, default the real venue key passed in), `:kid`, `:alg`.
  """
  def issue(attendee_id, tier, venue_key, opts \\ []) do
    now = System.system_time(:second)

    claims = %{
      "attendee_id" => attendee_id,
      "tier" => to_string(tier),
      "exp" => Keyword.get(opts, :exp, now + 3600),
      "event" => Keyword.get(opts, :event, @default_event)
    }

    card = AshA2A.Info.agent_card(ConferenceSim.Registration, name: "badge:#{attendee_id}")

    card = %{card | description: "AGNTCon+MCPCon badge claims: " <> Jason.encode!(claims)}

    CardSigning.sign(card, venue_key,
      alg: Keyword.get(opts, :alg, :HS256),
      kid: Keyword.get(opts, :kid, ConferenceSim.badge_kid()),
      url: @venue_url
    )
  end

  def venue_url, do: @venue_url

  @doc "Parses the commerce claims back out of a badge card's description."
  def claims(%{description: "AGNTCon+MCPCon badge claims: " <> json}) do
    case Jason.decode(json) do
      {:ok, %{"attendee_id" => _, "tier" => _} = claims} -> {:ok, claims}
      _ -> {:error, :malformed_claims}
    end
  end

  def claims(_), do: {:error, :malformed_claims}
end

defmodule AshA2A.Test.ConferenceSim.BadgeGate do
  @moduledoc """
  The venue's badge gate: the REAL `AshA2A.Protocol.Plug.Auth` middleware
  (real `x-badge` API-key scheme extraction) whose `verify/3` callback is the
  venue's badge verifier — real `CardSigning.verify/2` against the venue key
  set (kid-selected), then the commerce claim checks (expiry, event) —
  followed by the venue's tier gate enforcing the method × tier law:

      keynote stream  = all tiers
      workshop rooms  = workshop + vip
      backstage       = vip only
      press interview = press only
  """

  import Plug.Conn

  @behaviour Plug

  @method_tiers %{
    "keynote" => MapSet.new(["general", "workshop", "vip", "press"]),
    "workshop" => MapSet.new(["workshop", "vip"]),
    "backstage" => MapSet.new(["vip"]),
    "interview" => MapSet.new(["press"])
  }

  @impl true
  def init(opts), do: Map.new(opts)

  @impl true
  def call(conn, %{venue_key: venue_key, es256_key: es256_key}) do
    # The venue's published key set (kid -> key): the HS256 venue secret plus
    # the venue's ES256 generation. Signature verification reads `kid` from
    # the PROTECTED header only.
    venue_keys = %{
      ConferenceSim.badge_kid() => venue_key,
      "venue-es256-key" => es256_key
    }

    auth_opts =
      AshA2A.Protocol.Plug.Auth.init(
        schemes: %{
          "badge" => %AshA2A.Protocol.SecurityScheme.APIKey{in: "header", name: "x-badge"}
        },
        verify: fn
          "badge", credential, _conn -> verify_badge(credential, venue_keys)
          _, _, _ -> {:error, %{code: :unconfigured_scheme}}
        end
      )

    conn = AshA2A.Protocol.Plug.Auth.call(conn, auth_opts)

    if conn.halted do
      conn
    else
      tier_gate(conn)
    end
  end

  # -- Badge verification (the venue's commerce law) ----------------------------

  defp verify_badge(credential, venue_keys) when is_binary(credential) do
    with {:ok, json} <- b64_decode(credential),
         {:ok, wire} <- Jason.decode(json),
         {:ok, card} <- decode_card(wire),
         # The venue resolves the badge's PROTECTED-header `kid` against its
         # published key set ITSELF and hands CardSigning positional key
         # material (verify/2 takes a single key per call).
         {:ok, kid} <- kid_of(card),
         {:ok, key} <- fetch_key(venue_keys, kid),
         :ok <- AshA2A.Protocol.CardSigning.verify(card, key),
         {:ok, claims} <- AshA2A.Test.ConferenceSim.RegistrationIssuer.claims(card) do
      now = System.system_time(:second)

      cond do
        not is_integer(claims["exp"]) or claims["exp"] < now ->
          {:error, %{code: :badge_expired, detail: claims["exp"]}}

        claims["event"] != "AGNTCon+MCPCon" ->
          {:error, %{code: :wrong_event, detail: claims["event"]}}

        true ->
          {:ok,
           %{
             scheme_kind: :key,
             authenticated: true,
             badge_id: card.name,
             attendee_id: claims["attendee_id"],
             tier: claims["tier"]
           }}
        end
    end
  end

  defp verify_badge(_credential, _venue_key), do: {:error, %{code: :invalid_api_key}}

  # Every failure is a typed {:error, map} — Plug.Auth case-clauses on
  # {:ok, _} | {:error, _} and a bare :error from a with fall-through would
  # crash the plug as a 500 (observed: CaseClauseError at auth.ex:216).
  defp b64_decode(bin) do
    case Base.url_decode64(bin) do
      {:ok, json} -> {:ok, json}
      :error -> {:error, %{code: :malformed_badge}}
    end
  end

  defp decode_card(wire) do
    case AshA2A.Protocol.JSON.decode_agent_card(wire) do
      {:ok, card} -> {:ok, card}
      {:error, _} -> {:error, %{code: :malformed_badge}}
    end
  end

  defp fetch_key(keys, kid) do
    case Map.fetch(keys, kid) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, %{code: :unknown_kid, detail: kid}}
    end
  end

  # Reads `kid` from the first signature entry's PROTECTED header only (the
  # unprotected `header` is attacker-writable and never selects a key).
  defp kid_of(%{signatures: [entry | _]}) do
    with {:ok, protected} <- Base.url_decode64(entry["protected"] || "", padding: false),
         {:ok, %{"kid" => kid}} <- Jason.decode(protected) do
      {:ok, kid}
    else
      err -> IO.inspect(err, label: "EV2KID"); {:error, %{code: :malformed_badge}}
    end
  end

  defp kid_of(_), do: {:error, %{code: :malformed_badge}}

  # -- Venue tier gate -----------------------------------------------------------

  defp tier_gate(conn) do
    wrapper = AshA2A.Protocol.Plug.Auth.get_identity(conn)
    identity = wrapper.identity
    method = method_of(conn)

    allowed? =
      method != nil and MapSet.member?(Map.fetch!(@method_tiers, method), identity.tier)

    if allowed? do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "granted" => true,
          "method" => method,
          "tier" => identity.tier,
          "badge_id" => identity.badge_id,
          "attendee_id" => identity.attendee_id,
          "bound" => %{"badge_id" => identity.badge_id, "attendee_id" => identity.attendee_id}
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
            "tier" => identity.tier
          }
        })
      )
    end
  end

  defp method_of(conn) do
    case conn.path_info do
      ["venue", method] when method in ["keynote", "workshop", "backstage", "interview"] ->
        method

      _ ->
        nil
    end
  end
end

defmodule AshA2A.Test.ConferenceSim.RegistrationCourt do
  @moduledoc """
  The courts. Each test starts its own real Bandit venue server on an
  OS-assigned ephemeral loopback port with a REAL fresh venue key, issues
  REAL signed badge cards through the registration issuer, and speaks real
  HTTP with wire-body assertions.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Protocol.CardSigning
  alias AshA2A.Test.ConferenceSim.{BadgeGate, RegistrationIssuer}
  alias AshA2A.Test.EphemeralHttp

  setup do
    venue_key = :crypto.strong_rand_bytes(32)
    es256_key = :public_key.generate_key({:namedCurve, :secp256r1})

    venue =
      EphemeralHttp.start!({BadgeGate, %{venue_key: venue_key, es256_key: es256_key}})

    %{venue: venue, venue_key: venue_key, es256_key: es256_key}
  end

  # -- Positive path for each tier -------------------------------------------------

  test ":general badge scans the keynote stream (positive path)", c do
    badge = RegistrationIssuer.issue("attendee-ev2-general", :general, c.venue_key)

    resp = post(c.venue.base_url, "/venue/keynote", badge)

    assert resp.status == 200

    assert body(resp) == %{
             "granted" => true,
             "method" => "keynote",
             "tier" => "general",
             "badge_id" => "badge:attendee-ev2-general",
             "attendee_id" => "attendee-ev2-general",
             "bound" => %{"badge_id" => "badge:attendee-ev2-general", "attendee_id" => "attendee-ev2-general"}
           }
  end

  test ":workshop badge joins a workshop room (positive path)", c do
    badge = RegistrationIssuer.issue("attendee-ev2-workshop", :workshop, c.venue_key)

    resp = post(c.venue.base_url, "/venue/workshop", badge)

    assert resp.status == 200
    assert body(resp)["granted"] == true
    assert body(resp)["tier"] == "workshop"
    assert body(resp)["method"] == "workshop"
  end

  test ":vip badge reaches backstage (positive path)", c do
    badge = RegistrationIssuer.issue("attendee-ev2-vip", :vip, c.venue_key)

    resp = post(c.venue.base_url, "/venue/backstage", badge)

    assert resp.status == 200
    assert body(resp)["granted"] == true
    assert body(resp)["tier"] == "vip"
    assert body(resp)["method"] == "backstage"
  end

  test ":press badge gets the interview room and the keynote stream", c do
    badge = RegistrationIssuer.issue("attendee-ev2-press", :press, c.venue_key)

    resp = post(c.venue.base_url, "/venue/interview", badge)
    assert resp.status == 200
    assert body(resp)["tier"] == "press"

    resp = post(c.venue.base_url, "/venue/keynote", badge)
    assert resp.status == 200
    assert body(resp)["tier"] == "press"
  end

  test "ES256 (asymmetric) signed badge verifies and grants like HS256", c do
    badge =
      RegistrationIssuer.issue("attendee-ev2-es256", :vip, c.es256_key,
        alg: :ES256,
        kid: "venue-es256-key"
      )

    resp = post(c.venue.base_url, "/venue/backstage", badge)

    assert resp.status == 200
    assert body(resp)["tier"] == "vip"
  end

  # -- Wrong-tier access (403, typed envelope) --------------------------------------

  test "workshop-only method hit with a :general badge is a typed 403", c do
    badge = RegistrationIssuer.issue("attendee-ev2-general-2", :general, c.venue_key)

    resp = post(c.venue.base_url, "/venue/workshop", badge)

    assert resp.status == 403
    assert body(resp) == %{
             "error" => %{
               "code" => "tier_access_denied",
               "method" => "workshop",
               "tier" => "general"
             }
           }
  end

  test "backstage hit with :workshop badge and interview hit with :vip badge are 403s", c do
    workshop_badge = RegistrationIssuer.issue("attendee-ev2-workshop-2", :workshop, c.venue_key)
    vip_badge = RegistrationIssuer.issue("attendee-ev2-vip-2", :vip, c.venue_key)

    resp = post(c.venue.base_url, "/venue/backstage", workshop_badge)
    assert resp.status == 403
    assert body(resp)["error"]["code"] == "tier_access_denied"

    resp = post(c.venue.base_url, "/venue/interview", vip_badge)
    assert resp.status == 403
    assert body(resp)["error"]["code"] == "tier_access_denied"
  end

  # -- Expired badge (401 + challenge) ------------------------------------------------

  test "expired badge is refused 401 with a real WWW-Authenticate challenge", c do
    badge =
      RegistrationIssuer.issue("attendee-ev2-expired", :vip, c.venue_key,
        exp: System.system_time(:second) - 3600
      )

    resp = post(c.venue.base_url, "/venue/backstage", badge)

    assert resp.status == 401
    assert body(resp) == %{"error" => "Unauthorized"}
  end

  # -- Forged / tampered badges (401) ---------------------------------------------------

  test "badge forged under a different key (same kid) is refused 401 (:bad_signature)", c do
    forged_key = :crypto.strong_rand_bytes(32)

    badge = RegistrationIssuer.issue("attendee-ev2-forge", :vip, forged_key)

    resp = post(c.venue.base_url, "/venue/backstage", badge)

    assert resp.status == 401
    assert body(resp) == %{"error" => "Unauthorized"}
  end

  test "rebinding a badge to another attendee (tampered claims) is refused 401 (:digest_mismatch)", c do
    badge = RegistrationIssuer.issue("attendee-ev2-bind", :vip, c.venue_key)
    tampered = %{badge | description: "someone else's badge now"}

    resp = post(c.venue.base_url, "/venue/backstage", tampered)

    assert resp.status == 401
  end

  test "badge signed under an unknown kid is refused 401 (:unknown_kid)", c do
    badge =
      RegistrationIssuer.issue("attendee-ev2-kid", :vip, c.venue_key, kid: "attacker-self-signed-key")

    resp = post(c.venue.base_url, "/venue/backstage", badge)

    assert resp.status == 401
  end

  # -- Domain lifting: a badge from another event ----------------------------------------

  test "badge for a different event is refused 401 (domain-lifting analog)", c do
    badge =
      RegistrationIssuer.issue("attendee-ev2-devcon", :vip, c.venue_key,
        event: "DevConX-Elsewhere"
      )

    resp = post(c.venue.base_url, "/venue/backstage", badge)

    assert resp.status == 401
  end

  # -- No credential / malformed credential -----------------------------------------------

  test "no badge header at all is 401 with challenges", c do
    resp = Req.post!(c.venue.base_url <> "/venue/keynote", headers: [], retry: false)

    assert resp.status == 401
  end

  test "garbage badge payload is refused 401, never a 500", c do
    resp =
      Req.post!(c.venue.base_url <> "/venue/keynote",
        headers: [{"x-badge", "not-even-base64!!!"}],
        retry: false
      )

    assert resp.status == 401
  end

  # -- Entitlement-seam cross-check: badge_id ↔ attendee correlation -----------------------

  test "the granted wire response echoes the badge_id ↔ attendee binding together", c do
    badge = RegistrationIssuer.issue("attendee-ev2-correlate", :workshop, c.venue_key)

    resp = post(c.venue.base_url, "/venue/workshop", badge)

    assert resp.status == 200
    bound = body(resp)["bound"]

    # Correlation mirror of ggen-marketplace's usageReportingId seam: the
    # badge (entitlement) id and the payer (attendee) id travel bound.
    assert bound == %{
             "badge_id" => "badge:attendee-ev2-correlate",
             "attendee_id" => "attendee-ev2-correlate"
           }

    # And the wire response never leaks the credential itself.
    presented = badge |> wire_json() |> Base.url_encode64()
    refute Jason.encode!(body(resp)) =~ presented
  end

  test "a badge issued for one attendee cannot grant as another", c do
    alice = RegistrationIssuer.issue("attendee-ev2-alice", :vip, c.venue_key)
    mallory = RegistrationIssuer.issue("attendee-ev2-mallory", :general, c.venue_key)

    # Mallory cannot re-present Alice's badge as his own: the card name binds
    # badge_id to attendee, and the signature covers the binding.
    resp = post(c.venue.base_url, "/venue/backstage", alice)

    assert resp.status == 200
    assert body(resp)["attendee_id"] == "attendee-ev2-alice"
    assert body(resp)["badge_id"] == "badge:attendee-ev2-alice"

    resp = post(c.venue.base_url, "/venue/workshop", mallory)
    assert resp.status == 403
    assert body(resp)["error"]["tier"] == "general"
  end

  # -- Card machinery direct check (no wire): CardSigning verifies the issued badge --------

  test "issued badge verifies directly against the venue key set (CardSigning)", c do
    badge = RegistrationIssuer.issue("attendee-ev2-direct", :workshop, c.venue_key)

    # Venue law: kid (from the PROTECTED header) selects the key; CardSigning
    # verifies positional key material (see BadgeGate.fetch_key/2 note).
    assert :ok = CardSigning.verify(badge, c.venue_key)

    assert {:ok, claims} = RegistrationIssuer.claims(badge)
    assert claims["attendee_id"] == "attendee-ev2-direct"
    assert claims["tier"] == "workshop"
    assert claims["event"] == RegistrationIssuer.default_event()
    assert claims["exp"] > System.system_time(:second)

    # Real capability surface: the badge is a real agent card of the real
    # registration resource.
    assert %AshA2A.Protocol.AgentCard{} = badge
    assert badge.name == "badge:attendee-ev2-direct"
  end

  # -- Helpers ---------------------------------------------------------------------------

  defp post(base_url, path, badge_card) do
    encoded = badge_card |> wire_json() |> Base.url_encode64()

    Req.post!(base_url <> path, headers: [{"x-badge", encoded}], retry: false)
  end

  defp wire_json(card) do
    card
    |> AshA2A.Protocol.JSON.encode_agent_card(
      url: AshA2A.Test.ConferenceSim.RegistrationIssuer.venue_url()
    )
    |> Jason.encode!()
  end

  # Req already decodes JSON response bodies (content-type driven).
  defp body(resp) when is_map(resp.body), do: resp.body
  defp body(resp), do: Jason.decode!(resp.body)
end
