defmodule AshA2A.Protocol.CardSigning do
  @moduledoc """
  End-to-end signing and verification of A2A v1.0 agent cards
  (`%AshA2A.Protocol.AgentCard{}` `signatures` field — a list of JWS objects
  each carrying `"protected"`, `"signature"` and `"header"` members, as
  documented on `AshA2A.Protocol.JSON.encode_agent_card/2`).

  `sign/3` canonicalizes the card payload with the already-vendored RFC 8785
  machinery (`Jcs.encode/1`, the same canonicalizer
  `Sa2aCrypto.SignedMessage.build/1` and `Sa2aCrypto.Registry.File` use —
  no second canonicalizer is hand-rolled here) and appends a detached compact
  JWS entry to `card.signatures` (existing signatures are preserved). `verify/2`
  recomputes the JCS digest of the card **minus** the `signatures` member and
  verifies every JWS entry.

  ## Signatures are computed over the v1.0 WIRE-PROJECTED card

  The digest is taken over the **codec-canonical form** of the card — the
  exact JSON document a wire peer sees — not the in-memory struct. The
  canonicalization pipeline in both `sign/3` and `verify/2` is:

      card
      |> AshA2A.Protocol.JSON.encode_agent_card(url: ...)   # v1.0 projection
      |> Jason.encode!() |> Jason.decode!()                 # wire normalization
      |> Map.delete("signatures")                           # detached payload
      |> Jcs.encode()                                       # RFC 8785 bytes

  Because `AshA2A.Protocol.JSON.encode_agent_card/2`
  (lib/ash_a2a/protocol/json.ex) projects to the v1.0 wire shape, in-memory
  struct fields absent from the wire **do not participate** in the digest:
  the top-level `protocol_version` (v1.0 carries `protocolVersion` only
  inside `supportedInterfaces[]` — the codec never emits a top-level member,
  and V10/V11 courts pin its absence) and `preferred_transport` (struct-only
  by spec — the v1.0 proto has no such member; json.ex correctly never reads
  or emits it) are excluded by construction.
  This makes signing **wire-stable**: a card signed in memory verifies
  identically after `encode_agent_card/2` -> `Jason` -> `decode_agent_card/1`
  codec round trip, because signer and verifier digest the same projected
  document.

  ## JWS entry shape

      %{
        "protected"  => b64url(JCS(%{"alg" => "HS256", "typ" => "a2a-card",
                                     "sha256" => <lowercase-hex card digest>})),
        "header"     => %{"alg" => "HS256", "typ" => "a2a-card"},
        "signature"  => b64url(HMAC-SHA256(key, protected_b64 <> "." <> jcs_bytes))
      }

  The signature is a detached-payload JWS per RFC 7797: the signing input is
  `b64url(protected) <> "." <> jcs_bytes` (the canonical card bytes are the
  detached payload; the compact serialization carries an empty payload
  segment). The protected header carries the SHA-256 digest of the canonical
  card bytes so a verifier can distinguish *key* failure (`:bad_signature`)
  from *content* tampering (`:digest_mismatch`).

  ## Wire integration points

  - **Serving (server side)**: `AshA2A.Protocol.Plug.init/1` accepts an
    `:agent_card_opts` keyword list that is forwarded verbatim to
    `AshA2A.Protocol.JSON.encode_agent_card/2`; the serve path is
    `serve_agent_card/2` in `lib/ash_a2a/protocol/plug.ex`
    (`GenServer.call(agent, :get_agent_card)` -> `encode_agent_card/2` ->
    `Jason.encode!/1` -> 200). Because `encode_agent_card/2` emits the
    `signatures` member from `card_field(opts, card, :signatures, [])`, a
    pre-signed card struct flows onto the wire unchanged — sign the struct
    with `AshA2A.Protocol.CardSigning.sign/3` before handing it to the plug,
    or pass the `signatures` entries through `:agent_card_opts`.
  - **Consuming (client side)**: clients verify **post-decode** — the decode
    path is `AshA2A.Protocol.Client.discover/2` in
    `lib/ash_a2a/protocol/client.ex`, which feeds the HTTP body through
    `AshA2A.Protocol.JSON.decode_agent_card/1` (the `signatures` member lands
    on the struct), after which the client calls
    `AshA2A.Protocol.CardSigning.verify/2` on the decoded card before
    trusting it.

  ## Options

  - `:alg` — signing algorithm; `:HS256` / `"HS256"` (HMAC-SHA256 shared
    secret via `:crypto`), `:RS256` / `"RS256"` (RSA PKCS#1 v1.5 over
    SHA-256) and `:ES256` / `"ES256"` (ECDSA P-256, raw 64-byte `r || s`
    JWS form) are supported. RS256/ES256 keys may be OTP `:public_key`
    records or PEM binaries. Any other value: `sign/3` raises
    `ArgumentError`; `verify/2` refuses entries whose protected header
    claims an unsupported alg as `{:error, {:malformed, ...}}`.
  - `:kid` — key identifier. When set, both the JWS protected header and the
    unprotected `header` carry `"kid"` (A2A v1.0 spec §8.4.2
    CARD-SIGN-003: the protected header MUST include `alg` AND `kid`).
    Verification reads `kid` from the PROTECTED header ONLY (AT5 advisory —
    the unprotected `header` is attacker-writable and never selects a key).
  - `:url` — agent endpoint URL, forwarded to
    `AshA2A.Protocol.JSON.encode_agent_card/2` as the seed for the default
    `supportedInterfaces[0].url`. Defaults to the card's `url` field, then
    the first `supported_interfaces` entry's `url` (what
    `decode_agent_card/1` restores); only consulted when the card carries no
    `supported_interfaces`.

  ## Errors

  `verify/2` verifies **all** entries and returns `:ok` only when every entry
  verifies; it reports the **first** failure with its zero-based index:

      {:error, {:bad_signature, %{index: 1}}}    # HMAC mismatch (wrong key)
      {:error, {:digest_mismatch, %{index: 0}}}  # card content tampered
      {:error, {:malformed, detail}}             # structurally invalid entry

  A card with an empty `signatures` list is refused as
  `{:error, {:malformed, :no_signatures}}` — a vacuous
  all-signatures-verified admission is never returned.

  ## Key rotation and JWKS publication

  `verify/2`'s second argument is the key OR the key set. A rotation set is
  a map `kid -> key material`, a list of `{kid, key}` pairs, or a whole JWKS
  document (`%{"keys" => [...]}` as produced by `jwks/1`). The entry's
  PROTECTED header `kid` selects the key; an unknown `kid` refuses as
  `{:error, {:bad_signature, %{index: i, reason: :unknown_kid}}}` and a
  missing one as `{:error, {:malformed, %{reason: :missing_kid}}}`. Publishing
  multiple `kid`s at once (via `jwks/1` and the plug's `:jwks_keys` /
  `:jwks_path` options) lets old-generation and new-generation signatures
  both verify during a rotation window.
  """

  alias AshA2A.Protocol.AgentCard

  @alg "HS256"
  @algs ["HS256", "RS256", "ES256"]
  @typ "a2a-card"
  @digest_member "sha256"
  @ec_curve :secp256r1
  @ec_curve_oid {1, 2, 840, 10045, 3, 1, 7}
  @sig_type :"ECDSA-Sig-Value"

  @doc """
  Signs `card` with the requested algorithm (`:alg` option — HS256 by
  default, RS256 or ES256 for asymmetric deployments) over the JCS bytes of
  the **wire-projected**
  card payload (the card run through `AshA2A.Protocol.JSON.encode_agent_card/2`
  and a Jason round trip, minus its `signatures` member) and appends the
  resulting detached compact JWS to `card.signatures`, preserving any existing
  entries.

      key = :crypto.strong_rand_bytes(32)
      card = AshA2A.Protocol.CardSigning.sign(card, key)
      length(card.signatures) #=> 1

  See the moduledoc for the JWS entry shape and the `:alg` / `:kid` / `:url` options.

      iex> card = AshA2A.Info.agent_card(AshA2A.Test.Fixture.Echo)
      iex> key = :crypto.strong_rand_bytes(32)
      iex> signed = AshA2A.Protocol.CardSigning.sign(card, key)
      iex> length(signed.signatures)
      1
      iex> AshA2A.Protocol.CardSigning.verify(signed, key)
      :ok
  """
  @spec sign(AgentCard.t(), binary() | map() | tuple(), keyword()) :: AgentCard.t()
  def sign(card, key, opts \\ [])

  def sign(%AgentCard{} = card, key, opts) do
    sign_card(card, key, opts)
  end

  # A plain (atom-keyed) card map — e.g. the builder output served by an
  # agent's `get_agent_card` — signs exactly like the struct: it is coerced
  # through the struct so `%{card | signatures: ...}` stays total.
  def sign(%{} = card, key, opts) do
    sign_card(struct(AgentCard, Map.delete(card, :__struct__)), key, opts)
  end

  defp sign_card(card, key, opts) do
    alg = alg!(Keyword.get(opts, :alg, @alg))
    kid = Keyword.get(opts, :kid)

    jcs_bytes = jcs_bytes(card, opts)
    digest = sha256_hex(jcs_bytes)

    protected_map = %{"alg" => alg, "typ" => @typ, @digest_member => digest}
    protected_map = if kid, do: Map.put(protected_map, "kid", kid), else: protected_map

    protected = Jason.encode!(protected_map)
    protected_b64 = b64url_encode(protected)

    signature =
      raw_sign(alg, key, signing_input(protected_b64, jcs_bytes))

    entry = %{
      "protected" => protected_b64,
      "header" => protected_map,
      "signature" => b64url_encode(signature)
    }

    %{card | signatures: card.signatures ++ [entry]}
  end

  @doc """
  Verifies every JWS entry on `card` against the canonical (JCS) digest of the
  wire-projected card payload recomputed from the card **minus** its
  `signatures` member. The card is run through the same codec projection and
  Jason normalization as `sign/3`, so an in-memory card and its
  `encode_agent_card/2` -> `Jason` -> `decode_agent_card/1` round-tripped form
  verify identically.

      :ok = AshA2A.Protocol.CardSigning.verify(card, key)

  Returns `:ok` when all entries verify, otherwise
  `{:error, {:bad_signature | :digest_mismatch | :malformed, detail}}` for the
  first failing entry (`detail` carries its zero-based `index`).
  """
  @spec verify(AgentCard.t() | map(), key_or_keys(), keyword()) ::
          :ok | {:error, {:bad_signature | :digest_mismatch | :malformed, term()}}
  def verify(card, key_or_keys, opts \\ []) when is_map(card) do
    case Map.get(card, :signatures, []) do
      [] ->
        {:error, {:malformed, :no_signatures}}

      signatures ->
        jcs_bytes = jcs_bytes(card, opts)
        digest = sha256_hex(jcs_bytes)

        signatures
        |> Enum.with_index()
        |> Enum.reduce_while(:ok, fn {entry, index}, :ok ->
          case verify_entry(entry, key_or_keys, jcs_bytes, digest, index) do
            :ok -> {:cont, :ok}
            {:error, _} = error -> {:halt, error}
          end
        end)
    end
  end

  # ------------------------------------------------------------------
  # Per-entry verification
  # ------------------------------------------------------------------

  defp verify_entry(entry, key_or_keys, jcs_bytes, digest, index) when is_map(entry) do
    with {:ok, protected_b64} <- string_member(entry, "protected", index),
         {:ok, signature_b64} <- string_member(entry, "signature", index),
         {:ok, protected_json} <- b64url_decode(protected_b64, index),
         {:ok, protected} <- decode_shape(protected_json, index),
         {:ok, signature} <- b64url_decode(signature_b64, index),
         :ok <- check_alg(protected, index),
         {:ok, key} <- resolve_key(protected, key_or_keys, index) do
      input = signing_input(protected_b64, jcs_bytes)

      cond do
        # Digest BEFORE signature: the header digest binds the card content the
        # signer saw, so a post-signing content mutation is reported as
        # :digest_mismatch (the recomputed digest differs) while a wrong
        # key — content unchanged, digest matching — reports as
        # :bad_signature. The signature still covers the exact JCS bytes, so a
        # tamper-plus-header-rewrite falls through to :bad_signature.
        protected[@digest_member] != digest ->
          {:error,
           {:digest_mismatch,
            %{index: index, expected: protected[@digest_member], actual: digest}}}

        not signature_valid?(protected["alg"], input, signature, key) ->
          {:error, {:bad_signature, %{index: index}}}

        true ->
          :ok
      end
    end
  end

  defp verify_entry(_entry, _key, _jcs_bytes, _digest, index),
    do: {:error, {:malformed, %{index: index, reason: :not_a_map}}}

  defp check_alg(%{"alg" => alg}, _index) when alg in @algs, do: :ok

  defp check_alg(%{"alg" => alg}, index),
    do: {:error, {:malformed, %{index: index, reason: :unsupported_alg, alg: alg}}}

  # -- Key resolution --------------------------------------------------------
  #
  # AT5 advisory: the `kid` that selects the verification key is read from the
  # PROTECTED header ONLY — the unprotected `header` member (which mirrors the
  # protected parameters on entries we sign) is attacker-writable and is never
  # consulted for key selection.

  @type key_or_keys ::
          binary()
          | map()
          | {atom(), term()}
          | [key_or_keys()]

  # HS256: the positional key must be the shared secret.
  defp resolve_key(%{"alg" => "HS256"}, key, _index) when is_binary(key), do: {:ok, key}

  defp resolve_key(%{"alg" => "HS256"}, _key_or_keys, index),
    do: {:error, {:malformed, %{index: index, reason: :missing_key}}}

  # A single JWK map given positionally is a key, not a rotation set.
  defp resolve_key(%{"alg" => alg}, %{"kty" => _} = jwk, _index),
    do: {:ok, public_material(alg, jwk)}

  # A JWKS document (a map carrying a "keys" list) is always a rotation set.
  defp resolve_key(protected, %{"keys" => keys} = _jwks, index) when is_list(keys),
    do: resolve_key(protected, keys, index)

  # Rotation set: kid -> key material. `kid` is taken from the PROTECTED
  # header only; the unprotected `header.kid` is never consulted.
  defp resolve_key(%{"alg" => alg} = protected, keys, index)
       when is_list(keys) or is_map(keys) do
    kid = Map.get(protected, "kid")

    cond do
      not is_binary(kid) ->
        {:error, {:malformed, %{index: index, reason: :missing_kid}}}

      true ->
        case find_kid(keys, kid) do
          {:ok, material} -> {:ok, public_material(alg, material)}
          :error -> {:error, {:bad_signature, %{index: index, reason: :unknown_kid, kid: kid}}}
        end
    end
  end

  # A binary that is not the HS256 secret for an asymmetric entry is a key
  # type mismatch (e.g. a forged alg claim over an HS256-signed card) —
  # refused, never raised on.
  defp resolve_key(%{"alg" => alg}, key, index) when is_binary(key),
    do: {:error, {:malformed, %{index: index, reason: :key_type_mismatch, alg: alg}}}

  # Single asymmetric key material given positionally.
  defp resolve_key(%{"alg" => alg}, material, _index),
    do: {:ok, public_material(alg, material)}

  defp find_kid(keys, kid) when is_map(keys) and not is_map_key(keys, "keys") do
    case Map.fetch(keys, kid) do
      {:ok, material} -> {:ok, material}
      :error -> :error
    end
  end

  defp find_kid(keys, kid) when is_list(keys) do
    Enum.find_value(keys, :error, fn
      {^kid, material} -> {:ok, material}
      %{"kid" => ^kid} = jwk -> {:ok, jwk}
      _ -> nil
    end)
  end

  defp find_kid(_keys, _kid), do: :error

  defp decode_shape(protected_json, index) do
    case Jason.decode(protected_json) do
      {:ok, %{} = protected} ->
        cond do
          not is_binary(protected["alg"]) ->
            {:error, {:malformed, %{index: index, reason: :missing_alg}}}

          not is_binary(protected[@digest_member]) ->
            {:error, {:malformed, %{index: index, reason: :missing_digest}}}

          true ->
            {:ok, protected}
        end

      {:ok, _} ->
        {:error, {:malformed, %{index: index, reason: :protected_not_an_object}}}

      {:error, %Jason.DecodeError{}} ->
        {:error, {:malformed, %{index: index, reason: :protected_not_json}}}
    end
  end

  defp string_member(entry, name, index) do
    case Map.get(entry, name) do
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:malformed, %{index: index, reason: {:missing_member, name}}}}
    end
  end

  # ------------------------------------------------------------------
  # Canonicalization (REUSE, not reimplementation)
  # ------------------------------------------------------------------

  # Canonical bytes = RFC 8785 (JCS) of the card payload, via exactly the
  # canonicalizer vendored for Sa2aCrypto (`Jcs.encode/1`, the one
  # Sa2aCrypto.SignedMessage.build/1 and Sa2aCrypto.Registry.File call).
  # The payload is the CODEC-CANONICAL form: the card is first projected to
  # the v1.0 wire shape by AshA2A.Protocol.JSON.encode_agent_card/2 (the
  # exact document a wire peer sees — see json.ex) and then normalized
  # through the same Jason encode/decode round trip the transport performs,
  # so in-memory-only struct fields (top-level protocol_version,
  # preferred_transport) never enter the digest and signatures are stable
  # across a codec round trip.
  defp jcs_bytes(card, opts) do
    card
    |> wire_payload(opts)
    |> Jcs.encode()
  end

  defp wire_payload(card, opts) do
    card
    # ALL serve-time projection opts flow into the digest payload, not just
    # :url — a card served with :capabilities / :supported_interfaces opts
    # must digest the document that actually goes on the wire (the served
    # bytes and the signed bytes are the same document, or verification
    # against the served card fails).
    |> AshA2A.Protocol.JSON.encode_agent_card([url: wire_url(card, opts)] ++ opts)
    |> Map.delete("signatures")
    |> jason_round_trip()
  end

  # encode_agent_card/2 requires :url to seed the default supportedInterfaces
  # entry. Prefer an explicit opt, then the card's url field, then the first
  # supported interface's url (what decode_agent_card/1 restores on the
  # client); the fallback only matters when the card carries no interfaces.
  defp wire_url(card, opts) do
    Keyword.get_lazy(opts, :url, fn ->
      Map.get(card, :url) ||
        case card |> Map.get(:supported_interfaces, []) |> List.first() do
          %{url: url} when is_binary(url) -> url
          %{"url" => url} when is_binary(url) -> url
          _ -> ""
        end
    end)
  end

  # The exact normalization any JSON transport applies: serialize and
  # reparse, collapsing atom keys, structs and any other in-memory shape
  # into the string-keyed document that goes over the wire.
  defp jason_round_trip(map), do: map |> Jason.encode!() |> Jason.decode!()

  defp alg!(:HS256), do: @alg
  defp alg!("HS256"), do: @alg
  defp alg!(:RS256), do: "RS256"
  defp alg!("RS256"), do: "RS256"
  defp alg!(:ES256), do: "ES256"
  defp alg!("ES256"), do: "ES256"

  defp alg!(other) do
    raise ArgumentError,
          "AshA2A.Protocol.CardSigning supports only HS256, RS256 and ES256, got: #{inspect(other)}"
  end

  # ------------------------------------------------------------------
  # Signing / verifying dispatch
  # ------------------------------------------------------------------

  # Signs the signing input with the requested algorithm and returns the
  # raw JWS signature bytes (ES256 is the 64-byte raw `r || s` form per
  # RFC 7518 §3.4, not the DER ECDSA-Sig-Value OTP returns natively).
  defp raw_sign("HS256", key, input) when is_binary(key),
    do: :crypto.mac(:hmac, :sha256, key, input)

  defp raw_sign("RS256", key, input),
    do: :public_key.sign(input, :sha256, private_material(key))

  defp raw_sign("ES256", key, input) do
    input
    |> then(&:public_key.sign(&1, :sha256, private_material(key)))
    |> der_to_raw_es256()
  end

  defp signature_valid?("HS256", input, signature, key) when is_binary(key) do
    secure_equal?(:crypto.mac(:hmac, :sha256, key, input), signature)
  end

  defp signature_valid?("RS256", input, signature, key) do
    :public_key.verify(input, :sha256, signature, public_material("RS256", key))
  end

  defp signature_valid?("ES256", input, signature, key) do
    case raw_to_der_es256(signature) do
      {:ok, der} -> :public_key.verify(input, :sha256, der, public_material("ES256", key))
      :error -> false
    end
  end

  defp signature_valid?(_alg, _input, _signature, _key), do: false

  # ES256 JWS signatures are the raw 64-byte `r || s` (RFC 7518 §3.4); OTP's
  # :public_key produces/consumes DER ECDSA-Sig-Value, so convert both ways.
  @es256_coord_size 32

  defp der_to_raw_es256(der) do
    {@sig_type, r, s} = :public_key.der_decode(@sig_type, der)
    pad = &pad32/1
    pad.(r) <> pad.(s)
  end

  defp raw_to_der_es256(raw) when byte_size(raw) == @es256_coord_size * 2 do
    r = :binary.decode_unsigned(binary_part(raw, 0, @es256_coord_size))
    s = :binary.decode_unsigned(binary_part(raw, @es256_coord_size, @es256_coord_size))
    {:ok, :public_key.der_encode(@sig_type, {@sig_type, r, s})}
  end

  defp raw_to_der_es256(_), do: :error

  defp pad32(int) when is_integer(int),
    do: int |> :binary.encode_unsigned() |> pad32_binary()

  defp pad32_binary(bin) when byte_size(bin) > @es256_coord_size,
    do: binary_part(bin, byte_size(bin) - @es256_coord_size, @es256_coord_size)

  defp pad32_binary(bin),
    do: :binary.copy(<<0>>, @es256_coord_size - byte_size(bin)) <> bin

  # ------------------------------------------------------------------
  # Key material normalization (PEM / OTP records / JWK maps)
  # ------------------------------------------------------------------

  @doc """
  Builds a JWKS (`%{"keys" => [...]}`) document from key material — the
  publication surface a verifier fetches to resolve the `kid` carried in a
  signature's PROTECTED header.

  Accepts a single key or a list of `{kid, key}` pairs (rotation: every
  generation currently published appears, so old and new signatures both
  verify during a rotation window).

      key = :public_key.generate_key({:namedCurve, :secp256r1})
      AshA2A.Protocol.CardSigning.jwks([{"k1", key}])
      #=> %{"keys" => [%{"kty" => "EC", "crv" => "P-256", "x" => ..., "y" => ...,
      #                  "kid" => "k1", "alg" => "ES256", "use" => "sig"}]}

  RSA material yields `%{"kty" => "RSA", "n" => ..., "e" => ...}` entries;
  EC material yields `%{"kty" => "EC", "crv" => "P-256", ...}`. Only PUBLIC
  members are ever emitted — private scalars (`d`, `p`, `q`, ...) are never
  serialized.
  """
  @spec jwks(key_or_keys() | [{binary(), term()}]) :: map()
  def jwks(keys) do
    entries =
      keys
      |> List.wrap()
      |> Enum.map(fn
        {kid, material} -> jwk_entry(material, kid)
        material -> jwk_entry(material, nil)
      end)

    %{"keys" => entries}
  end

  # -- Public key extraction (for verification and JWKS publication) --------

  defp public_material("RS256", %{"kty" => "RSA"} = jwk), do: rsa_public_from_jwk(jwk)
  defp public_material("RS256", material), do: rsa_public(material)

  defp public_material("ES256", %{"kty" => "EC"} = jwk), do: ec_public_from_jwk(jwk)
  defp public_material("ES256", material), do: ec_public(material)

  defp public_material(_alg, material), do: material

  defp rsa_public({:RSAPublicKey, _n, _e} = rec), do: rec

  defp rsa_public({:RSAPrivateKey, _v, n, e, _d, _p, _q, _dp, _dq, _qi, _other}),
    do: {:RSAPublicKey, n, e}

  defp rsa_public("-----BEGIN" <> _ = pem) do
    case first_pem_entry(pem, [:RSAPublicKey, :RSAPrivateKey, :SubjectPublicKeyInfo]) do
      {:RSAPrivateKey, _v, n, e, _d, _p, _q, _dp, _dq, _qi, _other} -> {:RSAPublicKey, n, e}
      {:RSAPublicKey, _n, _e} = rec -> rec
      other -> raise ArgumentError, "unsupported RSA PEM entry: #{inspect(elem(other, 0))}"
    end
  end

  defp rsa_public(%{"kty" => "RSA"} = jwk), do: rsa_public_from_jwk(jwk)

  defp rsa_public(other),
    do: raise(ArgumentError, "unsupported RSA key material: #{inspect(other)}")

  defp rsa_public_from_jwk(%{"n" => n, "e" => e}) do
    {:RSAPublicKey, :binary.decode_unsigned(b64url_decode!(n)), :binary.decode_unsigned(b64url_decode!(e))}
  end

  defp ec_public({:ECPoint, _point} = rec), do: rec
  defp ec_public({{:ECPoint, _point}, _params} = rec), do: rec

  defp ec_public({:ECPrivateKey, _v, _priv, params, point, _extra}) when is_binary(point) do
    {{:ECPoint, point}, curve_param(params)}
  end

  defp ec_public("-----BEGIN" <> _ = pem) do
    case first_pem_entry(pem, [:ECPrivateKey, :SubjectPublicKeyInfo, :ECPublicKey]) do
      {:ECPrivateKey, _v, _priv, params, point, _extra} when is_binary(point) ->
        {{:ECPoint, point}, curve_param(params)}

      other ->
        raise ArgumentError, "unsupported EC PEM entry: #{inspect(elem(other, 0))}"
    end
  end

  defp ec_public(%{"kty" => "EC"} = jwk), do: ec_public_from_jwk(jwk)

  defp ec_public(other),
    do: raise(ArgumentError, "unsupported EC key material: #{inspect(other)}")

  defp ec_public_from_jwk(%{"crv" => "P-256", "x" => x, "y" => y}) do
    point = <<0x04, b64url_decode!(x)::binary, b64url_decode!(y)::binary>>
    {{:ECPoint, point}, {:namedCurve, @ec_curve}}
  end

  defp ec_public_from_jwk(%{"crv" => other}),
    do: raise(ArgumentError, "unsupported EC curve: #{other} (only P-256/ES256 is supported)")

  defp curve_param({:namedCurve, @ec_curve}), do: {:namedCurve, @ec_curve}
  defp curve_param({:namedCurve, @ec_curve_oid}), do: {:namedCurve, @ec_curve}

  defp curve_param(other),
    do: raise(ArgumentError, "unsupported EC curve parameters: #{inspect(other)}")

  # -- Private key extraction (for signing) ----------------------------------

  defp private_material({:RSAPrivateKey, _v, _n, _e, _d, _p, _q, _dp, _dq, _qi, _other} = rec),
    do: rec

  defp private_material({:ECPrivateKey, _v, _priv, _params, _point, _extra} = rec), do: rec

  defp private_material("-----BEGIN" <> _ = pem) do
    case first_pem_entry(pem, [:RSAPrivateKey, :ECPrivateKey]) do
      {:RSAPrivateKey, _v, _n, _e, _d, _p, _q, _dp, _dq, _qi, _other} = rec -> rec
      {:ECPrivateKey, _v, _priv, _params, _point, _extra} = rec -> rec
      other -> raise ArgumentError, "unsupported private PEM entry: #{inspect(elem(other, 0))}"
    end
  end

  defp private_material(other),
    do: raise(ArgumentError, "unsupported private key material: #{inspect(other)}")

  defp first_pem_entry(pem, supported) do
    case :public_key.pem_decode(pem) do
      [entry] -> decode_pem_entry(entry, supported)
      entries when is_list(entries) and entries != [] -> decode_pem_entry(hd(entries), supported)
      [] -> raise ArgumentError, "no PEM entries found"
    end
  end

  defp decode_pem_entry(entry, supported) do
    case :public_key.pem_entry_decode(entry) do
      %{__struct__: _} = other ->
        raise ArgumentError, "unsupported PEM key structure: #{inspect(other)}"

      rec ->
        if elem(rec, 0) in supported do
          rec
        else
          raise ArgumentError, "unexpected PEM key type: #{inspect(elem(rec, 0))}"
        end
    end
  end

  # -- JWKS entry construction -----------------------------------------------

  defp jwk_entry(material, kid) do
    jwk =
      case material do
        {:RSAPublicKey, _n, _e} = rec ->
          {:RSAPublicKey, n, e} = rsa_public(rec)
          %{"kty" => "RSA", "n" => b64url_uint(n), "e" => b64url_uint(e), "alg" => "RS256"}

        {:RSAPrivateKey, _v, _n, _e, _d, _p, _q, _dp, _dq, _qi, _other} = rec ->
          {:RSAPublicKey, n, e} = rsa_public(rec)
          %{"kty" => "RSA", "n" => b64url_uint(n), "e" => b64url_uint(e), "alg" => "RS256"}

        {:ECPrivateKey, _v, _priv, params, point, _extra} ->
          ec_jwk_from_point(point, curve_param(params))

        {{:ECPoint, _point}, _params} = rec ->
          ec_jwk_from_point_rec(rec)

        %{"kty" => _} = jwk ->
          jwk

        other ->
          raise ArgumentError, "cannot build JWKS entry from: #{inspect(other)}"
      end

    jwk = Map.put(jwk, "use", "sig")
    if kid, do: Map.put(jwk, "kid", kid), else: jwk
  end

  defp ec_jwk_from_point(point, curve) when is_binary(point) do
    ec_jwk_from_point_rec({{:ECPoint, point}, curve})
  end

  defp ec_jwk_from_point_rec({{:ECPoint, point}, _params}) do
    <<0x04, x::binary-32, y::binary-32>> = point
    %{"kty" => "EC", "crv" => "P-256", "x" => b64url_encode(x), "y" => b64url_encode(y), "alg" => "ES256"}
  end

  defp b64url_uint(int), do: int |> :binary.encode_unsigned() |> b64url_encode()

  defp b64url_decode!(bin), do: Base.url_decode64!(bin, padding: false)

  defp signing_input(protected_b64, jcs_bytes),
    do: <<protected_b64::binary, ?., jcs_bytes::binary>>

  defp sha256_hex(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp b64url_encode(binary), do: Base.url_encode64(binary, padding: false)

  defp b64url_decode(binary, index) do
    case Base.url_decode64(binary, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, {:malformed, %{index: index, reason: :bad_base64url}}}
    end
  end

  defp secure_equal?(a, b) when byte_size(a) == byte_size(b),
    do: :crypto.hash_equals(a, b)

  defp secure_equal?(_, _), do: false
end
