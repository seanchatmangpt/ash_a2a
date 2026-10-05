# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Security.DLP.Pseudonym do
  @moduledoc """
  HMAC-derived deterministic, reversible pseudonymization (FR-02.2).

  For each detected sensitive span the filter mints a pseudonym token:

    * the AES-256-GCM data key is derived from the configured key via
      HMAC-SHA256; the per-value nonce is derived as
      `HMAC(key, type || pattern-name || plaintext)` truncated to 12 bytes,
    * the ciphertext is therefore deterministic: same key + same plaintext +
      same type => byte-identical token, stable across occurrences (and
      across restarts when a persistent key is configured),
    * reversal is AES-GCM authenticated decryption with the same key; a wrong
      key fails the tag check and the token is left on the wire untouched.

  The key is never logged: telemetry carries counts and durations only.
  """

  @prefix "dlt1_"

  @type_code %{pan: 1, ssn: 2, api_key: 3, phi: 4}
  @code_type %{1 => :pan, 2 => :ssn, 3 => :api_key, 4 => :phi}

  @doc "Token namespace prefix shared by all pseudonyms."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @doc """
  Mints the deterministic pseudonym for `plaintext` under `key`. `type` is
  one of `:pan`, `:ssn`, `:api_key`, `:phi`; `name` distinguishes PHI
  pattern families inside the `:phi` type (empty for built-in types).
  """
  @spec token(binary, :pan | :ssn | :api_key | :phi, binary, String.t()) :: String.t()
  def token(plaintext, type, key, name \\ "")

  def token(plaintext, type, key, name)
      when is_binary(plaintext) and is_binary(key) and (is_binary(name) or is_atom(name)) do
    name = if is_atom(name), do: Atom.to_string(name), else: name
    code = Map.fetch!(@type_code, type)
    aes_key = :crypto.mac(:hmac, :sha256, key, "ash_a2a/dlp/aes-256-gcm")

    nonce =
      :crypto.mac(:hmac, :sha256, key, <<code::8, name::binary, 0, plaintext::binary>>)
      |> binary_part(0, 12)

    {ct, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, aes_key, nonce, plaintext, aad(code, name), true)

    header = <<code::8, byte_size(name)::8, name::binary, nonce::binary-size(12), tag::binary-size(16)>>
    @prefix <> Base.url_encode64(header <> ct, padding: false)
  end

  @doc """
  Reverses a token minted by `token/4`. Returns `{:ok, plaintext, type}` or
  `:error` (malformed token or wrong key -- the token stays on the wire).
  """
  @spec reveal(binary, binary) :: {:ok, binary, :pan | :ssn | :api_key | :phi} | :error
  def reveal(token, key) when is_binary(token) and is_binary(key) do
    with {:ok, bin} <- decode(token),
         <<code::8, nlen::8, name::binary-size(nlen), nonce::binary-size(12),
           tag::binary-size(16), ct::binary>> <- bin,
         type when type != nil <- Map.get(@code_type, code),
         plain when is_binary(plain) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             aes_key(key),
             nonce,
             ct,
             aad(code, name),
             tag,
             false
           ) do
      {:ok, plain, type}
    else
      _ -> :error
    end
  end

  def reveal(_, _), do: :error

  defp aad(code, ""), do: <<"ASH_A2A_DLP", code::8>>
  defp aad(code, name), do: <<"ASH_A2A_DLP", code::8, 0, name::binary>>

  defp aes_key(key), do: :crypto.mac(:hmac, :sha256, key, "ash_a2a/dlp/aes-256-gcm")

  defp decode(token) do
    case String.split_at(token, byte_size(@prefix)) do
      {@prefix, rest} ->
        case Base.url_decode64(rest, padding: false) do
          {:ok, bin} -> {:ok, bin}
          :error -> :error
        end

      _ ->
        :error
    end
  end
end
