# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Passport do
  @moduledoc """
  The Agent Passport — a signed, verifiable, portable identity document for
  an agent (the AAIF identity direction).

  A passport binds three things under one Merkle root and one detached JWS:

  - the agent's **identity** — its A2A v1.0 agent card
    (`AshA2A.Protocol.AgentCard`), carried as the passport subject and
    cross-checkable against `AshA2A.Protocol.CardSigning` signatures;
  - its **capability attestations** — one JSON document per attested
    capability;
  - its **evidence chain** — the supporting evidence entries.

  Every attestation and evidence entry is a Merkle leaf (RFC 6962-style
  domain-separated SHA-256 via `AshA2A.Passport.Merkle`, attestations
  first, then evidence, in document order). The leaf list and the Merkle
  root are carried in the passport's `merkle` member; the canonical
  passport document (JCS/RFC 8785, the vendored `Jcs.encode/1`
  canonicalizer — no second canonicalizer) is signed with the same
  detached compact JWS scheme `AshA2A.Protocol.CardSigning` uses: HS256,
  protected header carrying the SHA-256 digest of the canonical document,
  so key failure reports `:bad_signature` and content tampering reports
  `:digest_mismatch`.

  ## Issuing

      passport =
        AshA2A.Passport.issue(card, attestations, evidence,
          key: issuing_key,
          issuer: "urn:ash-a2a:issuer:main",
          expires_at: some_datetime
        )

  ## Verifying (fail-closed)

      :ok = AshA2A.Passport.verify(passport, key)

  `verify/2` refuses:

  - a structurally malformed document (`{:error, {:malformed, detail}}`),
    including a document with no signatures
    (`{:error, {:malformed, :no_signatures}}`) — a vacuous
    all-signatures-verified admission is never returned;
  - a document whose pinned entries no longer hash to the Merkle leaves
    the document claims are signed —
    `{:error, {:capability_mutated, detail}}`, where `detail` carries the
    mutated entry's position, the current and signed leaf digests, and the
    **Merkle audit path over the signed leaves** — the proof pinning the
    change to that entry (`Merkle.valid_proof?/3` recomputes the signed
    root from it);
  - an expired document (`{:error, {:expired, detail}}`);
  - a document whose JWS does not verify
    (`{:error, {:bad_signature, ...}}` / `{:error, {:digest_mismatch,
    ...}}`);
  - a document listed on a *verified* revocation list
    (`{:error, {:revoked, detail}}` — see `:revocation` below);
  - when `:card_key` is supplied, a subject card whose
    `AshA2A.Protocol.CardSigning` signature does not verify.

  Verification order is chosen for diagnostics, never for leniency: any
  single failure refuses the document outright, and an adaptive attacker
  who rewrites `merkle` to match a mutated attestation lands in
  `:digest_mismatch`/`:bad_signature` instead.

  ## Revocation

      list = AshA2A.Passport.revoke(passport, key, reason: "key-compromise")
      :ok = AshA2A.Passport.Revocation.verify(list, key)
      {:error, {:revoked, _}} =
        AshA2A.Passport.verify(passport, key, revocation: list)

  `:revocation` accepts a verified `%AshA2A.Passport.Revocation.List{}`
  (or a wire map); when given, the list itself is re-verified first and a
  list that fails verification fails the passport (fail closed — an
  unverifiable list contributes nothing to an admission).

  ## Serving

  `AshA2A.Passport.Plug` serves the passport and its revocation list at
  well-known GET paths.
  """

  alias AshA2A.Passport.Merkle
  alias AshA2A.Passport.Revocation
  alias AshA2A.Protocol.AgentCard
  alias AshA2A.Protocol.CardSigning
  alias AshA2A.Protocol.JSON

  @alg "HS256"
  @typ "a2a-passport"
  @digest_member "sha256"

  @hex_digest_length 64

  defmodule Document do
    @moduledoc """
    The in-memory passport document.

    `:attestations` and `:evidence` are JSON-shaped, string-keyed maps in
    document order (attestations are pinned by leaves `0..n-1`, evidence by
    leaves `n..`); `:merkle` is `%{"root" => hex, "leaves" => [hex]}`;
    `:signatures` carries detached JWS entries in the
    `AshA2A.Protocol.CardSigning` shape; `:issued_at` / `:expires_at` are
    ISO 8601 UTC strings.
    """

    @enforce_keys [:id, :issuer, :subject, :attestations, :evidence, :merkle, :issued_at]
    defstruct [
      :id,
      :issuer,
      :subject,
      :attestations,
      :evidence,
      :merkle,
      :issued_at,
      :expires_at,
      signatures: []
    ]

    @type t :: %__MODULE__{}
  end

  # ------------------------------------------------------------------
  # Issuance
  # ------------------------------------------------------------------

  @doc """
  Issues a passport binding `card` (the subject) to `attestations` and
  `evidence`, Merkle-rooted and JWS-signed with `key`.

  `attestations` must be a non-empty list of JSON-shaped maps; `evidence`
  a list of JSON-shaped maps (may be empty). Required options: `:key`
  (binary HMAC key) and `:issuer` (non-empty string IRI). Optional:
  `:expires_at` (`DateTime`, strictly in the future), `:now`
  (`DateTime`, default `DateTime.utc_now()`), `:id` (passport id string,
  default `urn:ash-a2a:passport:<32 random hex>`).

  Raises `ArgumentError` on contract violations (issuance is a
  constructor, verification is fail-closed-typed).
  """
  @spec issue(AgentCard.t(), [map()], [map()], keyword()) :: Document.t()
  def issue(%AgentCard{} = card, attestations, evidence, opts \\ [])
      when is_list(attestations) and is_list(evidence) and is_list(opts) do
    key = required_key(opts)
    issuer = required_issuer(opts)
    now = datetime_opt(opts, :now, DateTime.utc_now())
    expires_at = expires_opt(opts, now)

    :ok = check_entries!(attestations, :attestations)
    :ok = check_entries!(evidence, :evidence)

    leaves = leaf_hashes(attestations, evidence)
    {:ok, root} = Merkle.root(leaves)

    %Document{
      id: Keyword.get(opts, :id, "urn:ash-a2a:passport:" <> random_hex()),
      issuer: issuer,
      subject: card,
      attestations: Enum.map(attestations, &jason_round_trip/1),
      evidence: Enum.map(evidence, &jason_round_trip/1),
      merkle: %{"root" => hex_encode(root), "leaves" => Enum.map(leaves, &hex_encode/1)},
      issued_at: DateTime.to_iso8601(now),
      expires_at: expires_at,
      signatures: []
    }
    |> sign(key)
  end

  # ------------------------------------------------------------------
  # Signing (detached JWS over the JCS canonical document)
  # ------------------------------------------------------------------

  @doc """
  Appends a detached compact JWS entry over the canonical (JCS) wire
  document to `passport.signatures`, preserving existing entries — the
  same scheme, canonicalizer and error taxonomy as
  `AshA2A.Protocol.CardSigning.sign/3`.
  """
  @spec sign(Document.t(), binary()) :: Document.t()
  def sign(%Document{} = passport, key) when is_binary(key) do
    jcs_bytes = canonical_bytes(passport)
    digest = sha256_hex(jcs_bytes)

    protected = Jason.encode!(%{"alg" => @alg, "typ" => @typ, @digest_member => digest})
    protected_b64 = Base.url_encode64(protected, padding: false)

    signature = :crypto.mac(:hmac, :sha256, key, <<protected_b64::binary, ?., jcs_bytes::binary>>)

    entry = %{
      "protected" => protected_b64,
      "header" => %{"alg" => @alg, "typ" => @typ},
      "signature" => Base.url_encode64(signature, padding: false)
    }

    %{passport | signatures: passport.signatures ++ [entry]}
  end

  # ------------------------------------------------------------------
  # Verification (fail-closed)
  # ------------------------------------------------------------------

  @doc """
  Verifies `passport` under `key`, fail-closed. See the moduledoc for the
  full refusal taxonomy.

  Options:

  - `:now` — verification instant (`DateTime`, default now); drives
    `:expired`.
  - `:revocation` — `%Revocation.List{}` or wire map; when present the
    list is verified first (with `:revocation_key`, default `key`) and a
    listed passport id is refused.
  - `:card_key` — when present, additionally cross-checks the subject
    card's `AshA2A.Protocol.CardSigning` signatures under this key.
  """
  @spec verify(Document.t() | map(), binary(), keyword()) ::
          :ok
          | {:error,
             {:malformed | :bad_signature | :digest_mismatch | :expired | :revoked, term()}
             | {:error, {:capability_mutated | :merkle_root_mismatch, term()}}}
  def verify(passport, key, opts \\ [])

  def verify(%Document{} = passport, key, opts) when is_binary(key) and is_list(opts),
    do: do_verify(passport, key, opts)

  def verify(map, key, opts) when is_map(map) and is_binary(key) and is_list(opts),
    do: with({:ok, doc} <- from_json(map), do: do_verify(doc, key, opts))

  def verify(_, _, _), do: {:error, {:malformed, :not_a_passport}}

  defp do_verify(%Document{} = passport, key, opts) do
    with :ok <- check_structure(passport),
         :ok <- check_merkle_leaves(passport),
         :ok <- check_merkle_root(passport),
         :ok <- check_expiry(passport, opts),
         :ok <- check_signatures(passport, key),
         :ok <- check_revocation(passport, key, opts) do
      check_card_signatures(passport, opts)
    end
  end

  # ------------------------------------------------------------------
  # Wire shape (codec)
  # ------------------------------------------------------------------

  @doc "JSON bytes of the wire document."
  @spec to_json(Document.t()) :: binary()
  def to_json(%Document{} = passport), do: Jason.encode!(to_wire(passport))

  @doc """
  Decodes JSON bytes (or a wire map) into a `%Document{}`, or
  `{:error, {:malformed, detail}}` — never raises.
  """
  @spec from_json(binary() | map()) :: {:ok, Document.t()} | {:error, {:malformed, term()}}
  def from_json(binary) when is_binary(binary) do
    case Jason.decode(binary) do
      {:ok, map} -> from_json(map)
      {:error, %Jason.DecodeError{}} -> {:error, {:malformed, :not_json}}
    end
  end

  def from_json(map) when is_map(map) do
    with {:ok, id} <- binary_member(map, "id"),
         {:ok, issuer} <- binary_member(map, "issuer"),
         {:ok, subject_map} <- object_member(map, "subject"),
         {:ok, subject} <- decode_subject(subject_map),
         {:ok, attestations} <- map_list_member(map, "attestations"),
         {:ok, evidence} <- map_list_member(map, "evidence"),
         {:ok, merkle} <- merkle_member(map),
         {:ok, issued_at} <- binary_member(map, "issuedAt") do
      {:ok,
       %Document{
         id: id,
         issuer: issuer,
         subject: subject,
         attestations: attestations,
         evidence: evidence,
         merkle: merkle,
         issued_at: issued_at,
         expires_at: Map.get(map, "expiresAt"),
         signatures: Map.get(map, "signatures", [])
       }}
    else
      {:error, reason} -> {:error, {:malformed, reason}}
      {:missing, name} -> {:error, {:malformed, {:missing_member, name}}}
      {:bad, name} -> {:error, {:malformed, {:bad_member, name}}}
    end
  end

  def from_json(_), do: {:error, {:malformed, :not_a_map}}

  # ------------------------------------------------------------------
  # Revocation (delegates to AshA2A.Passport.Revocation)
  # ------------------------------------------------------------------

  @doc """
  Revokes `passport` (or a bare passport-id string): appends an entry to
  `opts[:list]` (creating a fresh signed list when absent) and re-signs.
  A fresh list requires `opts[:issuer]`. Also accepts `:reason`, `:now`,
  `:list_id`. Delegates to `AshA2A.Passport.Revocation.revoke/4`.
  """
  @spec revoke(Document.t() | String.t(), binary(), keyword()) :: Revocation.List.t()
  def revoke(passport_or_id, key, opts \\ [])

  def revoke(passport_or_id, key, opts) when is_binary(key) and is_list(opts),
    do: Revocation.revoke(passport_or_id, key, Keyword.get(opts, :list), opts)

  # ------------------------------------------------------------------
  # Verification steps
  # ------------------------------------------------------------------

  defp check_structure(%Document{} = p) do
    cond do
      not is_binary(p.id) or p.id == "" -> {:error, {:malformed, {:bad_member, "id"}}}
      not is_binary(p.issuer) or p.issuer == "" -> {:error, {:malformed, {:bad_member, "issuer"}}}
      not is_binary(p.issued_at) -> {:error, {:malformed, {:bad_member, "issuedAt"}}}
      not (is_list(p.attestations) and p.attestations != [] and Enum.all?(p.attestations, &is_map/1)) ->
        {:error, {:malformed, {:bad_member, "attestations"}}}

      not (is_list(p.evidence) and Enum.all?(p.evidence, &is_map/1)) ->
        {:error, {:malformed, {:bad_member, "evidence"}}}

      true -> :ok
    end
  end

  # The diagnostic core: compare the CURRENT entries' leaf hashes against
  # the leaves the document claims are signed. First mismatch wins, with
  # the audit path over the claimed-signed leaves — the proof that the
  # signed tree pinned the OLD value at this position.
  defp check_merkle_leaves(%Document{attestations: atts, evidence: ev, merkle: merkle} = p) do
    signed_leaves = signed_leaves(merkle)
    current = leaf_hashes(atts, ev)

    signed_leaves
    |> Enum.with_index()
    |> Enum.find_value(:ok, fn {signed_hex, position} ->
      signed_bin = Base.decode16!(signed_hex, case: :mixed)
      current_bin = Enum.at(current, position)

      if current_bin && :crypto.hash_equals(signed_bin, current_bin) do
        nil
      else
        {:error,
         {:capability_mutated,
          mutation_detail(p, position, signed_leaves, current_bin || <<>>) }}
      end
    end)
  end

  defp mutation_detail(%Document{} = p, position, signed_leaves, current_bin) do
    att_count = length(p.attestations)

    kind = if position < att_count, do: :attestation, else: :evidence
    index = if kind == :attestation, do: position, else: position - att_count

    {:ok, proof} = Merkle.proof(Enum.map(signed_leaves, &Base.decode16!(&1, case: :mixed)), position)

    entry =
      (kind == :attestation && Enum.at(p.attestations, index)) ||
        Enum.at(p.evidence, index)

    %{
      kind: kind,
      index: index,
      position: position,
      entry_id: entry_id(entry),
      leaf: hex_encode(current_bin),
      signed_leaf: Enum.at(signed_leaves, position),
      proof: proof,
      root: p.merkle["root"]
    }
  end

  defp check_merkle_root(%Document{merkle: merkle}) do
    leaves = Enum.map(signed_leaves(merkle), &Base.decode16!(&1, case: :mixed))

    case Merkle.root(leaves) do
      {:ok, root} ->
        if hex_encode(root) == String.downcase(merkle["root"]) do
          :ok
        else
          {:error, {:merkle_root_mismatch, %{expected: merkle["root"], actual: hex_encode(root)}}}
        end

      {:error, reason} ->
        {:error, {:merkle_root_mismatch, reason}}
    end
  end

  defp check_expiry(%Document{expires_at: nil}, _opts), do: :ok

  defp check_expiry(%Document{expires_at: expires_at}, opts) do
    now = datetime_opt(opts, :now, DateTime.utc_now())

    case DateTime.from_iso8601(expires_at) do
      {:ok, parsed, _} ->
        if DateTime.compare(parsed, now) == :lt do
          {:error, {:expired, %{expires_at: expires_at, now: DateTime.to_iso8601(now)}}}
        else
          :ok
        end

      :error ->
        {:error, {:malformed, {:bad_member, "expiresAt"}}}
    end
  end

  defp check_signatures(%Document{signatures: signatures} = passport, key) do
    case signatures do
      [] ->
        {:error, {:malformed, :no_signatures}}

      signatures ->
        jcs_bytes = canonical_bytes(passport)
        digest = sha256_hex(jcs_bytes)

        signatures
        |> Enum.with_index()
        |> Enum.reduce_while(:ok, fn {entry, index}, :ok ->
          case verify_entry(entry, key, jcs_bytes, digest, index) do
            :ok -> {:cont, :ok}
            {:error, _} = error -> {:halt, error}
          end
        end)
    end
  end

  defp check_revocation(%Document{id: id}, key, opts) do
    case Keyword.get(opts, :revocation) do
      nil ->
        :ok

      %{__struct__: AshA2A.Passport.Revocation.List} = list ->
        listed(list, id, key, opts)

      map when is_map(map) ->
        case Revocation.from_json(map) do
          {:ok, list} -> listed(list, id, key, opts)
          {:error, reason} -> {:error, {:revocation_list_malformed, reason}}
        end

      _ ->
        {:error, {:malformed, {:bad_opt, :revocation}}}
    end
  end

  defp listed(%{__struct__: AshA2A.Passport.Revocation.List} = list, id, key, opts) do
    list_key = Keyword.get(opts, :revocation_key, key)

    case Revocation.verify(list, list_key) do
      :ok ->
        case Revocation.entry_for(list, id) do
          {:ok, %{__struct__: AshA2A.Passport.Revocation.Entry} = entry} ->
            {:error, {:revoked, %{passport_id: id, reason: entry.reason, revoked_at: entry.revoked_at}}}

          :not_listed ->
            :ok
        end

      {:error, reason} ->
        {:error, {:revocation_list_unverified, reason}}
    end
  end

  defp check_card_signatures(%Document{subject: subject}, opts) do
    case Keyword.get(opts, :card_key) do
      nil -> :ok
      card_key when is_binary(card_key) -> CardSigning.verify(subject, card_key)
      _ -> {:error, {:malformed, {:bad_opt, :card_key}}}
    end
  end

  # ------------------------------------------------------------------
  # Leaves and canonicalization
  # ------------------------------------------------------------------

  defp leaf_hashes(attestations, evidence) do
    Enum.map(attestations, &leaf_hash/1) ++ Enum.map(evidence, &leaf_hash/1)
  end

  defp leaf_hash(entry), do: Merkle.leaf(Jcs.encode(jason_round_trip(entry)))

  defp signed_leaves(%{"leaves" => leaves}) when is_list(leaves), do: leaves
  defp signed_leaves(_), do: []

  defp canonical_bytes(%Document{} = passport),
    do: passport |> to_wire() |> Map.delete("signatures") |> jason_round_trip() |> Jcs.encode()

  defp to_wire(%Document{} = p) do
    base =
      %{
        "id" => p.id,
        "issuer" => p.issuer,
        "subject" => subject_wire(p.subject),
        "attestations" => Enum.map(p.attestations, &jason_round_trip/1),
        "evidence" => Enum.map(p.evidence, &jason_round_trip/1),
        "merkle" => p.merkle,
        "issuedAt" => p.issued_at
      }
      |> maybe_put("expiresAt", p.expires_at)

    Map.put(base, "signatures", p.signatures)
  end

  # The subject rides the wire as the v1.0 codec projection of the card —
  # the exact document a peer would discover at the agent-card endpoint —
  # so CardSigning digests recomputed over `doc.subject` match the card's
  # own wire form.
  defp subject_wire(%AgentCard{} = card) do
    card
    |> JSON.encode_agent_card(url: card.url)
    |> jason_round_trip()
  end

  defp decode_subject(subject_map) do
    case JSON.decode_agent_card(subject_map) do
      {:ok, %AgentCard{} = card} -> {:ok, card}
      {:error, reason} -> {:error, {:bad_subject, reason}}
    end
  end

  defp verify_entry(entry, key, jcs_bytes, digest, index) when is_map(entry) do
    with {:ok, protected_b64} <- string_sig_member(entry, "protected", index),
         {:ok, signature_b64} <- string_sig_member(entry, "signature", index),
         {:ok, protected_json} <- b64url_decode(protected_b64, index),
         {:ok, protected} <- decode_protected(protected_json, index),
         {:ok, signature} <- b64url_decode(signature_b64, index) do
      cond do
        protected["alg"] != @alg ->
          {:error, {:malformed, %{index: index, reason: :unsupported_alg}}}

        true ->
          expected = :crypto.mac(:hmac, :sha256, key, <<protected_b64::binary, ?., jcs_bytes::binary>>)

          cond do
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

  defp verify_entry(_entry, _key, _jcs_bytes, _digest, index),
    do: {:error, {:malformed, %{index: index, reason: :not_a_map}}}

  defp decode_protected(protected_json, index) do
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

  # ------------------------------------------------------------------
  # Small helpers
  # ------------------------------------------------------------------

  defp check_entries!(entries, kind) do
    if is_list(entries) and Enum.all?(entries, &is_map/1) and
         (kind == :evidence or entries != []) do
      :ok
    else
      raise ArgumentError,
            "AshA2A.Passport.issue/3 requires #{kind} to be " <>
              (if kind == :attestations, do: "a non-empty list", else: "a list") <>
              " of maps, got: #{inspect(entries)}"
    end
  end

  defp required_key(opts) do
    case Keyword.get(opts, :key) do
      key when is_binary(key) -> key
      _ -> raise ArgumentError, "AshA2A.Passport.issue/3 requires a binary :key"
    end
  end

  defp required_issuer(opts) do
    case Keyword.get(opts, :issuer) do
      issuer when is_binary(issuer) and issuer != "" -> issuer
      _ -> raise ArgumentError, "AshA2A.Passport.issue/3 requires a non-empty string :issuer"
    end
  end

  defp expires_opt(opts, now) do
    case Keyword.get(opts, :expires_at) do
      nil ->
        nil

      %DateTime{} = dt ->
        if DateTime.compare(dt, now) != :gt do
          raise ArgumentError, "AshA2A.Passport.issue/3 :expires_at must be in the future"
        end

        DateTime.to_iso8601(dt)

      _ ->
        raise ArgumentError, "AshA2A.Passport.issue/3 :expires_at must be a DateTime"
    end
  end

  defp datetime_opt(opts, key, default) do
    case Keyword.get(opts, key, default) do
      %DateTime{} = dt -> dt
      _ -> default
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp binary_member(map, name) when is_map(map) do
    case Map.get(map, name) do
      value when is_binary(value) -> {:ok, value}
      _ -> {:missing, name}
    end
  end

  defp object_member(map, name) when is_map(map) do
    case Map.get(map, name) do
      value when is_map(value) -> {:ok, value}
      _ -> {:bad, name}
    end
  end

  defp map_list_member(map, name) when is_map(map) do
    case Map.get(map, name) do
      value when is_list(value) and value != [] ->
        if Enum.all?(value, &is_map/1), do: {:ok, value}, else: {:bad, name}

      [] when name == "evidence" ->
        {:ok, []}

      _ ->
        {:bad, name}
    end
  end

  defp merkle_member(map) do
    case Map.get(map, "merkle") do
      %{"root" => root, "leaves" => leaves} = merkle
      when is_binary(root) and byte_size(root) == @hex_digest_length and is_list(leaves) ->
        if Enum.all?(leaves, &is_hex_digest/1) do
          {:ok, merkle}
        else
          {:bad, "merkle"}
        end

      _ ->
        {:bad, "merkle"}
    end
  end

  defp is_hex_digest(s) when is_binary(s) and byte_size(s) == @hex_digest_length do
    String.match?(s, ~r/^[0-9a-fA-F]{64}$/)
  end

  defp is_hex_digest(_), do: false

  defp entry_id(entry) when is_map(entry), do: Map.get(entry, "id")
  defp entry_id(_), do: nil

  defp string_sig_member(entry, name, index) do
    case Map.get(entry, name) do
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:malformed, %{index: index, reason: {:missing_member, name}}}}
    end
  end

  defp b64url_decode(binary, index) do
    case Base.url_decode64(binary, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, {:malformed, %{index: index, reason: :bad_base64url}}}
    end
  end

  defp sha256_hex(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp hex_encode(bin), do: Base.encode16(bin, case: :lower)

  defp secure_equal?(a, b) when byte_size(a) == byte_size(b), do: :crypto.hash_equals(a, b)
  defp secure_equal?(_, _), do: false

  defp jason_round_trip(map), do: map |> Jason.encode!() |> Jason.decode!()

  defp random_hex, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
end
