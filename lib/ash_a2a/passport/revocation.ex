# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Passport.Revocation do
  @moduledoc """
  Signed, portable revocation list for `AshA2A.Passport` documents.

  The list is a first-class signed document: an issuer accumulates
  revocation entries (one per revoked passport id), signs the whole list
  with the same detached JWS scheme `AshA2A.Protocol.CardSigning` uses
  (JCS canonical bytes, HS256, protected header carrying the SHA-256
  digest of the canonical list — key failure reports `:bad_signature`,
  content tampering reports `:digest_mismatch`), and publishes it at the
  revocation well-known path.

  Fail-closed: `verify/2` refuses an unsigned list
  (`{:error, {:malformed, :no_signatures}}`) and refuses entries whose
  protected header does not claim HS256. `AshA2A.Passport.verify/3`
  refuses a passport whose id is listed in a *verified* list; a list that
  itself fails verification contributes nothing to any decision.
  """

  defmodule Entry do
    @moduledoc """
    One revocation record: the passport id, why, when.
    """

    @enforce_keys [:passport_id, :reason, :revoked_at]
    defstruct [:passport_id, :reason, :revoked_at]

    @type t :: %__MODULE__{
            passport_id: String.t(),
            reason: String.t(),
            revoked_at: String.t()
          }
  end

  defmodule List do
    @moduledoc """
    The signed revocation-list document: id, issuer, ordered entries,
    signatures.
    """

    @enforce_keys [:id, :issuer, :updated_at, :entries]
    defstruct [:id, :issuer, :updated_at, :entries, signatures: []]

    @type t :: %__MODULE__{}
  end

  @alg "HS256"
  @typ "a2a-passport-revocation"
  @digest_member "sha256"

  @doc """
  Appends a revocation for `passport_id` (or a whole
  `AshA2A.Passport.Document`) to `list` — creating a fresh list when
  `list` is `nil` — and re-signs it with `key`. The list's signatures are
  replaced each call, so the published list always carries exactly the
  current issuer statement.

  Options: `:reason` (string, default `"unspecified"`), `:now`
  (`DateTime`), `:list_id`, `:issuer` (required when `list` is `nil`).
  """
  @spec revoke(String.t() | AshA2A.Passport.Document.t(), binary(), List.t() | nil, keyword()) ::
          List.t()
  def revoke(passport_or_id, key, list \\ nil, opts \\ [])

  # Runtime map match, NOT a compile-time struct expansion: expanding
  # %AshA2A.Passport.Document{} here would make the dependency cycle
  # Passport -> Revocation -> Passport a compile-time cycle. The `:subject`
  # key distinguishes a passport document from a revocation list (a list
  # carries no :subject).
  def revoke(%{id: id, subject: _} = _passport, key, list, opts) when is_binary(id),
    do: revoke(id, key, list, opts)

  def revoke(passport_id, key, list, opts)
      when is_binary(passport_id) and is_binary(key) and is_list(opts) do
    now = iso_datetime(opts, :now)

    entry = %Entry{
      passport_id: passport_id,
      reason: Keyword.get(opts, :reason, "unspecified"),
      revoked_at: now
    }

    base =
      list ||
        %List{
          id: Keyword.get(opts, :list_id, "urn:ash-a2a:passport-revocation:" <> random_hex()),
          issuer: Keyword.fetch!(opts, :issuer),
          updated_at: now,
          entries: []
        }

    # Re-signing after a content change REPLACES the signatures: stale
    # entries over earlier content would leave the published list
    # unverifiable (every prior digest mismatches).
    signed_list = %{base | entries: base.entries ++ [entry], updated_at: now, signatures: []}

    sign(signed_list, key)
  end

  @doc """
  Signs `list` with HMAC-SHA256 over the JCS bytes of the wire-projected
  list (minus its `signatures` member), appending a detached compact JWS
  entry — same scheme, canonicalizer and error taxonomy as
  `AshA2A.Protocol.CardSigning`.
  """
  @spec sign(List.t(), binary()) :: List.t()
  def sign(%List{} = list, key) when is_binary(key) do
    jcs_bytes = canonical_bytes(list)
    digest = sha256_hex(jcs_bytes)

    protected = Jason.encode!(%{"alg" => @alg, "typ" => @typ, @digest_member => digest})
    protected_b64 = Base.url_encode64(protected, padding: false)

    signature = :crypto.mac(:hmac, :sha256, key, <<protected_b64::binary, ?., jcs_bytes::binary>>)

    entry = %{
      "protected" => protected_b64,
      "header" => %{"alg" => @alg, "typ" => @typ},
      "signature" => Base.url_encode64(signature, padding: false)
    }

    %{list | signatures: list.signatures ++ [entry]}
  end

  @doc """
  Verifies every JWS entry on `list`, recomputing the canonical digest of
  the wire-projected list minus `signatures`. `:ok` only when all entries
  verify under `key`.
  """
  @spec verify(List.t() | map(), binary()) ::
          :ok | {:error, {:bad_signature | :digest_mismatch | :malformed, term()}}
  def verify(%List{} = list, key) when is_binary(key), do: do_verify(list, key)

  def verify(map, key) when is_map(map) and is_binary(key) do
    case from_json(map) do
      {:ok, list} -> do_verify(list, key)
      {:error, _} = error -> error
    end
  end

  @doc "The revocation entry for `passport_id`, or `:not_listed`."
  @spec entry_for(List.t(), String.t()) :: {:ok, Entry.t()} | :not_listed
  def entry_for(%List{entries: entries}, passport_id) when is_binary(passport_id) do
    case Enum.find(entries, &(&1.passport_id == passport_id)) do
      %Entry{} = entry -> {:ok, entry}
      nil -> :not_listed
    end
  end

  # ------------------------------------------------------------------
  # Wire shape
  # ------------------------------------------------------------------

  @doc "JSON bytes of the list document (including its signatures)."
  @spec to_json(List.t()) :: binary()
  def to_json(%List{} = list), do: Jason.encode!(to_wire(list))

  @doc "Decodes a wire map into a `%List{}`, or a malformed error."
  @spec from_json(map()) :: {:ok, List.t()} | {:error, {:malformed, term()}}
  def from_json(map) when is_map(map) do
    with {:ok, id} <- binary_member(map, "id"),
         {:ok, issuer} <- binary_member(map, "issuer"),
         {:ok, updated_at} <- binary_member(map, "updatedAt"),
         entries when is_list(entries) <- Map.get(map, "entries"),
         {:ok, decoded_entries} <- decode_entries(entries) do
      {:ok,
       %List{
         id: id,
         issuer: issuer,
         updated_at: updated_at,
         entries: decoded_entries,
         signatures: Map.get(map, "signatures", [])
       }}
    else
      {:error, reason} -> {:error, {:malformed, reason}}
      {:missing, name} -> {:error, {:malformed, {:missing_member, name}}}
      other -> {:error, {:malformed, {:bad_member, other}}}
    end
  end

  defp decode_entries(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn e, {:ok, acc} ->
      with {:ok, passport_id} <- binary_member(e, "passportId"),
           {:ok, reason} <- binary_member(e, "reason"),
           {:ok, revoked_at} <- binary_member(e, "revokedAt") do
        {:cont,
         {:ok, [%Entry{passport_id: passport_id, reason: reason, revoked_at: revoked_at} | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
        {:missing, name} -> {:halt, {:error, {:missing_member, name}}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _} = error -> error
    end
  end

  # ------------------------------------------------------------------
  # Canonicalization + JWS verification
  # ------------------------------------------------------------------

  defp do_verify(list, key) do
    case list.signatures do
      [] ->
        {:error, {:malformed, :no_signatures}}

      signatures ->
        jcs_bytes = canonical_bytes(list)
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
          expected = :crypto.mac(:hmac, :sha256, key, signing_input(protected_b64, jcs_bytes))

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

  defp to_wire(%List{} = list) do
    %{
      "id" => list.id,
      "issuer" => list.issuer,
      "updatedAt" => list.updated_at,
      "entries" =>
        Enum.map(list.entries, fn %Entry{} = e ->
          %{"passportId" => e.passport_id, "reason" => e.reason, "revokedAt" => e.revoked_at}
        end),
      "signatures" => list.signatures
    }
  end

  defp canonical_bytes(%List{} = list),
    do: list |> to_wire() |> Map.delete("signatures") |> jason_round_trip() |> Jcs.encode()

  defp string_sig_member(entry, name, index) do
    case Map.get(entry, name) do
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:malformed, %{index: index, reason: {:missing_member, name}}}}
    end
  end

  defp binary_member(map, name) when is_map(map) do
    case Map.get(map, name) do
      value when is_binary(value) -> {:ok, value}
      _ -> {:missing, name}
    end
  end

  defp b64url_decode(binary, index) do
    case Base.url_decode64(binary, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, {:malformed, %{index: index, reason: :bad_base64url}}}
    end
  end

  defp signing_input(protected_b64, jcs_bytes),
    do: <<protected_b64::binary, ?., jcs_bytes::binary>>

  defp sha256_hex(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp secure_equal?(a, b) when byte_size(a) == byte_size(b), do: :crypto.hash_equals(a, b)
  defp secure_equal?(_, _), do: false

  defp jason_round_trip(map), do: map |> Jason.encode!() |> Jason.decode!()

  defp iso_datetime(opts, key) do
    case Keyword.get(opts, key) do
      %DateTime{} = dt -> DateTime.to_iso8601(dt)
      binary when is_binary(binary) -> binary
      nil -> DateTime.to_iso8601(DateTime.utc_now())
    end
  end

  defp random_hex, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
end
