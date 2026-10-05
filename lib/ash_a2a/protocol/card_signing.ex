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

  - `:alg` — signing algorithm; `:HS256` / `"HS256"` (HMAC-SHA256 via
    `:crypto`) is supported. Any other value: `sign/3` raises
    `ArgumentError`; `verify/2` refuses entries whose protected header does
    not claim exactly `"HS256"` as `{:error, {:malformed, ...}}`.
  - `:kid` — key identifier. When set, both the JWS protected header and the
    unprotected `header` carry `"kid"` (A2A v1.0 spec §8.4.2
    CARD-SIGN-003: the protected header MUST include `alg` AND `kid`).
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
  """

  alias AshA2A.Protocol.AgentCard

  @alg "HS256"
  @typ "a2a-card"
  @digest_member "sha256"

  @doc """
  Signs `card` with HMAC-SHA256 over the JCS bytes of the **wire-projected**
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
  @spec sign(AgentCard.t(), binary(), keyword()) :: AgentCard.t()
  def sign(%AgentCard{} = card, key, opts \\ []) when is_binary(key) do
    alg = alg!(Keyword.get(opts, :alg, @alg))
    kid = Keyword.get(opts, :kid)

    jcs_bytes = jcs_bytes(card, opts)
    digest = sha256_hex(jcs_bytes)

    protected_map = %{"alg" => alg, "typ" => @typ, @digest_member => digest}
    protected_map = if kid, do: Map.put(protected_map, "kid", kid), else: protected_map

    protected = Jason.encode!(protected_map)
    protected_b64 = b64url_encode(protected)

    signature =
      :crypto.mac(:hmac, :sha256, key, signing_input(protected_b64, jcs_bytes))

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
  @spec verify(AgentCard.t() | map(), binary(), keyword()) ::
          :ok | {:error, {:bad_signature | :digest_mismatch | :malformed, term()}}
  def verify(card, key, opts \\ []) when is_map(card) and is_binary(key) do
    expected_alg = alg(Keyword.get(opts, :alg, @alg))

    case Map.get(card, :signatures, []) do
      [] ->
        {:error, {:malformed, :no_signatures}}

      signatures ->
        jcs_bytes = jcs_bytes(card, opts)
        digest = sha256_hex(jcs_bytes)

        signatures
        |> Enum.with_index()
        |> Enum.reduce_while(:ok, fn {entry, index}, :ok ->
          case verify_entry(entry, key, jcs_bytes, digest, index, expected_alg) do
            :ok -> {:cont, :ok}
            {:error, _} = error -> {:halt, error}
          end
        end)
    end
  end

  # ------------------------------------------------------------------
  # Per-entry verification
  # ------------------------------------------------------------------

  defp verify_entry(entry, key, jcs_bytes, digest, index, expected_alg) when is_map(entry) do
    with {:ok, protected_b64} <- string_member(entry, "protected", index),
         {:ok, signature_b64} <- string_member(entry, "signature", index),
         {:ok, protected_json} <- b64url_decode(protected_b64, index),
         {:ok, protected} <- decode_shape(protected_json, index),
         {:ok, signature} <- b64url_decode(signature_b64, index) do
      cond do
        protected["alg"] != expected_alg ->
          {:error, {:malformed, %{index: index, reason: :unsupported_alg}}}

        true ->
          expected = :crypto.mac(:hmac, :sha256, key, signing_input(protected_b64, jcs_bytes))

          cond do
            # Digest BEFORE MAC: the header digest binds the card content the
            # signer saw, so a post-signing content mutation is reported as
            # :digest_mismatch (the recomputed digest differs) while a wrong
            # key — content unchanged, digest matching — reports as
            # :bad_signature. The MAC still covers the exact JCS bytes, so a
            # tamper-plus-header-rewrite falls through to :bad_signature.
            protected[@digest_member] != digest ->
              {:error,
               {:digest_mismatch,
                %{index: index, expected: protected[@digest_member], actual: digest}}}

            not secure_equal?(expected, signature) ->
              {:error, {:bad_signature, %{index: index}}}

            true ->
              :ok
          end
      end
    end
  end

  defp verify_entry(_entry, _key, _jcs_bytes, _digest, index, _expected_alg),
    do: {:error, {:malformed, %{index: index, reason: :not_a_map}}}

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
    |> AshA2A.Protocol.JSON.encode_agent_card(url: wire_url(card, opts))
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

  defp alg(:HS256), do: @alg
  defp alg("HS256"), do: @alg
  defp alg(other), do: other

  defp alg!(:HS256), do: @alg
  defp alg!("HS256"), do: @alg

  defp alg!(other) do
    raise ArgumentError,
          "AshA2A.Protocol.CardSigning supports only HS256, got: #{inspect(other)}"
  end

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
