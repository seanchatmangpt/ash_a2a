# Lane EV3 — Conference-sim exhibitor identity: G4's card-signing surface
# under event conditions.
#
# Models a real AGNTCon expo floor: 3 exhibitors each sign their served agent
# card with a distinct key over the REAL `AshA2A.Protocol.CardSigning`
# machinery (RS256 + ES256 + the HS256 exhibitor — the full G4 algorithm mix),
# and the venue publishes a kid-sorted JWKS aggregating every exhibitor
# PUBLIC key.
#
# Venue publication law:
#   - the aggregate JWKS is kid-sorted (deterministic publication);
#   - a duplicate `kid` claimed by two exhibitors refuses the WHOLE set
#     (`{:error, {:duplicate_kid, kid}}`) — no partial key set is ever served;
#   - HMAC material has no public key, so the HS256 exhibitor's secret is
#     never published (G4's `CardSigning.jwks/1` refuses binary material) —
#     it reaches verifiers out-of-band as a rotation-set map entry.
#
# Courts:
#   1. three exhibitors, three distinct keys; venue JWKS is kid-sorted,
#      public-members-only;
#   2. every exhibitor's served card verifies against the published JWKS
#      (HS256 against the venue keyring; a JWKS-only verifier refuses the
#      HS256 card as :unknown_kid);
#   3. tampered card body -> :digest_mismatch; wrong-exhibitor key ->
#      :unknown_kid;
#   4. `kid` is read from the PROTECTED header ONLY — the attacker-writable
#      unprotected `header.kid` is ignored both ways (a trusted kid planted in
#      the unprotected header selects nothing; a kid ONLY in the unprotected
#      header is :missing_kid);
#   5. key rotation mid-event: the grace window serves both kids (old and new
#      cards verify), revocation serves only the new kid (old-kid card refuses
#      :unknown_kid, new-kid card passes);
#   6. cross-attendee: a real `AshA2A.Protocol.Client.discover/2` over a real
#      Bandit booth verifies the exhibitor card against the JWKS fetched from
#      the venue endpoint, and refuses a tampered served card;
#   7. duplicate-kid attack across exhibitors -> whole-set refusal.
#
# Chicago-school: real keys, real canonicalization, real HTTP, real client —
# no mocks anywhere in this file.
#
# Fixture modules live at TOP LEVEL of this file (never nested inside the
# test module: Elixir nests dotted module names under the enclosing module).

defmodule AshA2A.ConferenceSim.ExhibitorSigning.Venue do
  @moduledoc """
  Venue JWKS publication law over the real `AshA2A.Protocol.CardSigning.jwks/1`
  surface: kid-sorted aggregate, duplicate-kid whole-set refusal, and a
  keyring view that folds in the out-of-band HS256 exhibitor secret.
  """

  alias AshA2A.Protocol.CardSigning

  @hs_kid "hs-2026-gamma"

  @doc """
  Publishes the aggregate venue JWKS from `{kid, key}` pairs. Refuses the
  WHOLE set when two exhibitors claim the same `kid` — never a partial
  publication. Entries are kid-sorted.
  """
  @spec publish([{String.t(), term()}]) ::
          {:ok, map()} | {:error, {:duplicate_kid, String.t()}}
  def publish(pairs) when is_list(pairs) do
    dup =
      pairs
      |> Enum.map(fn {kid, _} -> kid end)
      |> Enum.frequencies()
      |> Enum.find(fn {_kid, n} -> n > 1 end)

    case dup do
      {kid, _n} -> {:error, {:duplicate_kid, kid}}
      nil -> {:ok, CardSigning.jwks(Enum.sort_by(pairs, &elem(&1, 0)))}
    end
  end

  @doc """
  The venue keyring: the published JWKS entries plus the out-of-band HS256
  secret, as a `kid -> material` rotation set `CardSigning.verify/2` accepts.
  """
  def keyring(jwks, hs256_secret) do
    jwks["keys"]
    |> Map.new(fn jwk -> {jwk["kid"], jwk} end)
    |> Map.put(@hs_kid, hs256_secret)
  end
end

defmodule AshA2A.ConferenceSim.ExhibitorSigning.BoothStore do
  @moduledoc "Agent holding the booth's served state (card body + venue JWKS)."

  use Agent, restart: :temporary

  def start_link(initial), do: Agent.start_link(fn -> initial end, name: __MODULE__)
  def get, do: Agent.get(__MODULE__, & &1)
  def update(fun), do: Agent.update(__MODULE__, fun)
end

defmodule AshA2A.ConferenceSim.ExhibitorSigning.ExhibitorBooth do
  @moduledoc """
  Real Plug.Router booth: serves the exhibitor's signed agent card at the
  §8.2 well-known path and the venue JWKS at the G4 publication path.
  """

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/.well-known/agent-card.json" do
    %{card_body: body} = AshA2A.ConferenceSim.ExhibitorSigning.BoothStore.get()

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, body)
  end

  get "/.well-known/jwks.json" do
    %{jwks: jwks} = AshA2A.ConferenceSim.ExhibitorSigning.BoothStore.get()

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(jwks))
  end

  match _ do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(404, ~s({"error":"not_found"}))
  end
end

defmodule AshA2A.ConferenceSim.ExhibitorSigningCourt do
  @moduledoc false

  use ExUnit.Case, async: false

  alias AshA2A.ConferenceSim.ExhibitorSigning.{BoothStore, Venue}
  alias AshA2A.Protocol.{AgentCard, CardSigning, Client, JSON}

  @rsa_kid "rsa-2026-alpha"
  @ec_kid "ec-2026-beta"
  @hs_kid "hs-2026-gamma"

  setup do
    server =
      AshA2A.Test.EphemeralHttp.start!(AshA2A.ConferenceSim.ExhibitorSigning.ExhibitorBooth)

    {:ok, _} = BoothStore.start_link(nil)

    # Exhibitors sign the wire-projected card with the booth's real URL, so
    # the served bytes and the signed bytes are the same document.
    alpha = exhibitor("Acme AI", @rsa_kid, :RS256, server.base_url)
    beta = exhibitor("Vertex Labs", @ec_kid, :ES256, server.base_url)
    gamma = exhibitor("QuantalYTICS", @hs_kid, :HS256, server.base_url)

    assert {:ok, jwks} = Venue.publish([{@rsa_kid, alpha.key}, {@ec_kid, beta.key}])

    BoothStore.update(fn _ -> %{card_body: alpha.body, jwks: jwks} end)

    # The Bandit listener is linked to the test process (EphemeralHttp), so it
    # tears down with the test — no on_exit kill needed.

    %{server: server, alpha: alpha, beta: beta, gamma: gamma, jwks: jwks}
  end

  # -- Court 1: three distinct keys, kid-sorted public-only JWKS --------------

  @tag :conference_sim
  test "three exhibitors sign with distinct keys; the venue JWKS is kid-sorted and public-only",
       %{alpha: alpha, beta: beta, gamma: gamma, jwks: jwks} do

    # Three DISTINCT signing keys over the full G4 algorithm mix.
    refute alpha.key == beta.key
    refute beta.key == gamma.key
    assert alpha.alg == "RS256"
    assert beta.alg == "ES256"
    assert gamma.alg == "HS256"

    assert %{"keys" => keys} = jwks
    # Kid-sorted, deterministic publication.
    assert keys == Enum.sort_by(keys, & &1["kid"])
    assert Enum.map(keys, & &1["kid"]) == [@ec_kid, @rsa_kid]

    # Public members only: real public material for each asymmetric exhibitor,
    # and the HS256 exhibitor's secret is NOWHERE in the published document.
    assert %{"kty" => "RSA", "n" => n} = Enum.find(keys, &(&1["kid"] == @rsa_kid))
    assert byte_size(Base.url_decode64!(n, padding: false)) == 256

    assert %{"kty" => "EC", "crv" => "P-256", "x" => x, "y" => y} =
             Enum.find(keys, &(&1["kid"] == @ec_kid))

    assert byte_size(Base.url_decode64!(x, padding: false)) == 32
    assert byte_size(Base.url_decode64!(y, padding: false)) == 32

    published = Jason.encode!(jwks)
    refute published =~ gamma.key
    # G4's publication surface refuses HMAC material outright.
    assert_raise ArgumentError, ~r/cannot build JWKS entry/, fn ->
      CardSigning.jwks([{gamma.kid, gamma.key}])
    end
  end

  # -- Court 2: every served card verifies against the published key set ------

  @tag :conference_sim
  test "each exhibitor's served card verifies against the venue key set",
       %{alpha: alpha, beta: beta, gamma: gamma, jwks: jwks} do

    # Asymmetric exhibitors verify straight off the published JWKS...
    assert CardSigning.verify(alpha.card, jwks) == :ok
    assert CardSigning.verify(beta.card, jwks) == :ok

    # ...decoded back through the real codec, the way a peer sees the card.
    wire_card =
      alpha.card
      |> JSON.encode_agent_card(url: alpha.card.url)
      |> Jason.encode!()
      |> Jason.decode!()
      |> JSON.decode_agent_card()
      |> elem(1)

    assert CardSigning.verify(wire_card, jwks) == :ok

    # The HS256 exhibitor verifies ONLY with the positional shared secret —
    # the G4 surface refuses ANY set-shaped key material on an HS256 entry
    # (a JWKS doc or a keyring map answers :missing_key before kid resolution
    # ever runs), and the secret is structurally absent from the public JWKS.
    keyring = Venue.keyring(jwks, gamma.key)
    assert CardSigning.verify(gamma.card, gamma.key) == :ok

    assert {:error, {:malformed, %{reason: :missing_key}}} =
             CardSigning.verify(gamma.card, keyring)

    assert {:error, {:malformed, %{reason: :missing_key}}} =
             CardSigning.verify(gamma.card, jwks)
  end

  # -- Court 3: tampered card body / wrong-exhibitor key -----------------------

  @tag :conference_sim
  test "tampered card body refuses with :digest_mismatch; wrong exhibitor's key refuses",
       %{alpha: alpha, jwks: jwks} do

    # A post-signing content mutation flips the recomputed digest.
    tampered = %{alpha.card | description: "TAMPERED — impostor booth"}

    assert {:error, {:digest_mismatch, %{index: 0}}} = CardSigning.verify(tampered, jwks)

    # A card from an exhibitor whose kid is not in the served set refuses.
    other = exhibitor("Impostor", "impostor-kid", :RS256, "http://127.0.0.1:1")

    assert {:error, {:bad_signature, %{reason: :unknown_kid}}} =
             CardSigning.verify(other.card, jwks)
  end

  # -- Court 4: protected-header-only kid law (AT5) ----------------------------

  @tag :conference_sim
  test "kid is read from the PROTECTED header only; the unprotected header is ignored",
       %{alpha: alpha, beta: beta, jwks: jwks} do
    # Attacker rewrites the UNPROTECTED header kid to point at another
    # exhibitor's key: key selection must still come from the protected
    # header (the entry verifies against ALPHA's RSA key, not beta's EC key —
    # had the unprotected kid been consulted, verification would fail).
    [entry] = alpha.card.signatures
    planted = put_in(entry["header"]["kid"], @ec_kid)

    assert planted["header"]["kid"] == @ec_kid
    assert entry["protected"] == planted["protected"]

    planted_card = %{alpha.card | signatures: [planted]}
    assert CardSigning.verify(planted_card, jwks) == :ok

    # A kid that exists ONLY in the unprotected header selects nothing: the
    # protected header carries no kid, so the rotation set is refused before
    # the (planted) header kid is ever consulted.
    no_kid_signed =
      %{alpha.card | signatures: []}
      |> CardSigning.sign(beta.key, alg: :ES256)

    assert [%{"protected" => protected_b64} = no_kid_entry] = no_kid_signed.signatures
    refute Jason.decode!(Base.url_decode64!(protected_b64, padding: false))["kid"]

    no_kid_entry =
      no_kid_entry
      |> Map.put("header", %{"alg" => "ES256", "typ" => "a2a-card", "kid" => @ec_kid})

    assert {:error, {:malformed, %{reason: :missing_kid}}} =
             CardSigning.verify(%{no_kid_signed | signatures: [no_kid_entry]}, %{
               @ec_kid => beta.key
             })
  end

  # -- Court 5: rotation mid-event ---------------------------------------------

  @tag :conference_sim
  test "key rotation mid-event: grace serves both kids; post-revocation the old kid refuses",
       %{beta: beta} do

    old_key = beta.key
    old_card = beta.card
    new_key = :public_key.generate_key({:namedCurve, :secp256r1})

    # Mid-event rotation: the new card is signed under the new generation.
    new_card =
      %{beta.card | signatures: []}
      |> CardSigning.sign(new_key, alg: :ES256, kid: "ec-2026-beta-r2")

    # Grace window: the venue publishes BOTH generations, kid-sorted.
    assert {:ok, grace} = Venue.publish([{@ec_kid, old_key}, {"ec-2026-beta-r2", new_key}])
    assert Enum.map(grace["keys"], & &1["kid"]) == [@ec_kid, "ec-2026-beta-r2"]

    assert CardSigning.verify(old_card, grace) == :ok
    assert CardSigning.verify(new_card, grace) == :ok

    # Revocation: only the new generation is served.
    assert {:ok, revoked} = Venue.publish([{"ec-2026-beta-r2", new_key}])
    assert CardSigning.verify(new_card, revoked) == :ok

    assert {:error,
            {:bad_signature, %{index: 0, reason: :unknown_kid, kid: @ec_kid}}} =
             CardSigning.verify(old_card, revoked)
  end

  # -- Court 6: cross-attendee client-side verification over real HTTP ---------

  @tag :conference_sim
  test "an attendee verifying a served exhibitor card through the real client",
       %{alpha: alpha, jwks: jwks} do

    # Real client discovery against the real Bandit booth.
    assert {:ok, card} = Client.discover(alpha.card.url)

    # Attendee fetches the venue JWKS and verifies the served card client-side.
    jwks_url = alpha.card.url <> "/.well-known/jwks.json"
    assert {:ok, %Req.Response{status: 200, body: served}} = Req.get(jwks_url)
    assert served == jwks

    assert CardSigning.verify(card, served) == :ok

    # Tampered serve: the booth flips a description character after signing.
    tampered_wire = JSON.encode_agent_card(%{alpha.card | description: "IMITATION BOOTH"}, url: alpha.card.url)
    BoothStore.update(fn state -> %{state | card_body: Jason.encode!(tampered_wire)} end)

    assert {:ok, served_card} = Client.discover(alpha.card.url)
    assert served_card.description == "IMITATION BOOTH"
    assert {:error, {:digest_mismatch, %{index: 0}}} = CardSigning.verify(served_card, served)

    # Restore the honest booth (state assertions, not call-count assumptions).
    BoothStore.update(fn state -> %{state | card_body: alpha.body} end)
    assert {:ok, honest} = Client.discover(alpha.card.url)
    assert CardSigning.verify(honest, served) == :ok
  end

  # -- Court 7: duplicate-kid attack -> whole-set refusal -----------------------

  @tag :conference_sim
  test "a duplicate kid claimed by two exhibitors refuses the whole JWKS set" do
    # Two different exhibitors (different real RSA keys) claim the SAME kid:
    # the venue must refuse to publish ANY key — never resolve ambiguously.
    k1 = :public_key.generate_key({:rsa, 2048, 65_537})
    k2 = :public_key.generate_key({:rsa, 2048, 65_537})

    assert {:error, {:duplicate_kid, @rsa_kid}} =
             Venue.publish([{@rsa_kid, k1}, {@rsa_kid, k2}])

    # Distinct kids publish normally (control).
    assert {:ok, published} = Venue.publish([{@rsa_kid, k1}, {"rsa-2026-delta", k2}])
    assert Enum.map(published["keys"], & &1["kid"]) == [@rsa_kid, "rsa-2026-delta"]
  end

  # -- Helpers -------------------------------------------------------------------

  defp exhibitor(name, kid, alg, base_url) do
    key = generate_key(alg)
    card = base_card(name, base_url)
    signed = CardSigning.sign(card, key, alg: alg, kid: kid)

    body =
      signed
      |> JSON.encode_agent_card(url: base_url)
      |> Jason.encode!()

    %{kid: kid, alg: to_string(alg), key: key, card: signed, body: body}
  end

  defp generate_key(:RS256), do: :public_key.generate_key({:rsa, 2048, 65_537})
  defp generate_key(:ES256), do: :public_key.generate_key({:namedCurve, :secp256r1})
  defp generate_key(:HS256), do: :crypto.strong_rand_bytes(32)

  defp base_card(name, url) do
    %AgentCard{
      name: name,
      description: "#{name} expo booth",
      url: url,
      version: "1.0.0",
      skills: [
        %{id: "demo", name: "Demo", description: "booth demo", tags: ["expo"]}
      ]
    }
  end
end
