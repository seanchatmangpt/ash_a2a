# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Security.CMEK do
  @moduledoc """
  AES-256-GCM payload layer of CMEK envelope encryption (PRD FR-03 /
  ARD §3.3).

  This module owns the symmetric primitive of the envelope pattern:

    * DEK generation via the crypto-secure PRNG
      (`:crypto.strong_rand_bytes(32)`, FR-03.2);
    * payload encryption/decryption under the DEK with AES-256-GCM,
      bound to a fixed domain-separator AAD so ciphertexts cannot be
      replayed under another algorithm;
    * the persisted envelope shape `{ciphertext, wrapped_dek, iv, tag,
      kek_version_id}` (ARD §3.3 step 4);
    * validation of untrusted envelopes and typed, non-raising
      refusals for tamper and malformed input.

  `AshA2A.Security.KeyManager` composes this layer with a
  `AshA2A.Security.KMS.Client` binding (KEK wrap/unwrap, rotation,
  fail-closed KMS handling).
  """

  @domain_separator "AshA2A.CMEK.v1:aes-256-gcm"

  @typedoc "256-bit Data Encryption Key."
  @type dek :: <<_::256>>

  @typedoc "Persisted envelope (ARD §3.3 step 4). The first five fields are the ARD-required set."
  @type envelope :: %{
          required(:ciphertext) => binary(),
          required(:wrapped_dek) => binary(),
          required(:iv) => <<_::96>>,
          required(:tag) => <<_::128>>,
          required(:kek_version_id) => pos_integer(),
          optional(:algorithm) => String.t(),
          optional(:kek_id) => String.t()
        }

  @type refusal_code ::
          :refused_cmek_tamper_detected | :refused_cmek_invalid_envelope
  @type refusal :: {:error, refusal_code(), String.t()}

  @doc "Generates an ephemeral 256-bit DEK via the crypto-secure PRNG (FR-03.2)."
  @spec generate_dek() :: dek()
  def generate_dek, do: :crypto.strong_rand_bytes(32)

  @doc "The envelope algorithm identifier."
  @spec algorithm() :: String.t()
  def algorithm, do: "AES-256-GCM"

  @doc """
  Encrypts `plaintext` under `dek` with AES-256-GCM under a fresh
  random 96-bit IV. Returns the payload triple for the envelope.
  """
  @spec encrypt_payload(binary(), dek()) ::
          {:ok, %{ciphertext: binary(), iv: <<_::96>>, tag: <<_::128>>}} | no_return()
  def encrypt_payload(plaintext, dek) when is_binary(plaintext) and is_binary(dek) do
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time(:aes_256_gcm, dek, iv, plaintext, aad: aad(), encrypt: true)

    {:ok, %{ciphertext: ciphertext, iv: iv, tag: tag}}
  end

  @doc """
  Decrypts the payload triple of `envelope` under `dek`, verifying the
  AEAD tag. Tamper with any authenticated input (ciphertext, tag, IV,
  AAD) is a typed refusal — never a crash, never a plaintext guess.
  """
  @spec decrypt_payload(envelope(), dek()) :: {:ok, binary()} | refusal()
  def decrypt_payload(envelope, dek) do
    with :ok <- validate_envelope(envelope) do
      try do
        :crypto.crypto_one_time(
          :aes_256_gcm,
          dek,
          envelope.iv,
          envelope.ciphertext,
          aad: aad(),
          tag: envelope.tag,
          encrypt: false
        )
      rescue
        _ ->
          {:error, :refused_cmek_tamper_detected,
           "AES-256-GCM authentication failed; ciphertext, tag, or IV was modified"}
      else
        plaintext when is_binary(plaintext) ->
          {:ok, plaintext}

        _ ->
          {:error, :refused_cmek_tamper_detected,
           "AES-256-GCM authentication failed; ciphertext, tag, or IV was modified"}
      end
    end
  end

  @doc """
  Validates an untrusted envelope: all five ARD-required fields are
  present, well-sized binaries (or a positive version id). A malformed
  envelope is a typed refusal, not a crash.
  """
  @spec validate_envelope(term()) :: :ok | refusal()
  def validate_envelope(envelope) when is_map(envelope) do
    with :ok <- require_binary(envelope, :ciphertext),
         :ok <- require_binary(envelope, :wrapped_dek),
         :ok <- require_sized(envelope, :iv, 12),
         :ok <- require_sized(envelope, :tag, 16) do
      case envelope do
        %{kek_version_id: v} when is_integer(v) and v > 0 -> :ok
        _ -> invalid_envelope_refusal(:kek_version_id)
      end
    end
  end

  def validate_envelope(_), do: invalid_envelope_refusal(:envelope_not_a_map)

  @doc "Domain-separator AAD binding every envelope to this algorithm."
  @spec aad() :: binary()
  def aad, do: @domain_separator

  # --- internals ---

  defp require_binary(envelope, field) do
    case envelope do
      %{^field => value} when is_binary(value) -> :ok
      _ -> invalid_envelope_refusal(field)
    end
  end

  defp require_sized(envelope, field, size) do
    case envelope do
      %{^field => value} when is_binary(value) and byte_size(value) == size -> :ok
      _ -> invalid_envelope_refusal(field)
    end
  end

  defp invalid_envelope_refusal(field) do
    {:error, :refused_cmek_invalid_envelope,
     "envelope field #{inspect(field)} is missing or malformed; refusing without decryption"}
  end
end
