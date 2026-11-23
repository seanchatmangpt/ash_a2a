# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Session.ChannelBind do
  @moduledoc """
  Channel-bind crypto for `AshA2A.Session.Statem` (R-04).

  Binds a client ECDSA P-256 public key to a session actor and verifies
  reconnect proofs signed by a WebCrypto non-extractable private key. Cookies
  and bearer tokens are not credentials on this surface: presenting either is a
  typed refusal. Standing is cryptographic proof over a server-issued challenge,
  not ambient HTTP session state.
  """

  @challenge_bytes 32
  @domain "ASHA2A-R04-CHANNEL-BIND-v1"

  @type public_key :: <<_::520>>
  @type challenge :: binary()
  @type signature :: <<_::512>>

  @doc "Domain-separated signing input for a reconnect challenge."
  @spec signing_input(term(), challenge()) :: binary()
  def signing_input(conn_id, challenge) when is_binary(challenge) do
    conn = conn_id |> to_string() |> :erlang.iolist_to_binary()
    @domain <> <<0>> <> conn <> <<0>> <> challenge
  end

  @doc "Fresh 32-byte challenge."
  @spec mint_challenge() :: challenge()
  def mint_challenge, do: :crypto.strong_rand_bytes(@challenge_bytes)

  @doc """
  Accepts a raw uncompressed P-256 point (`0x04 || x || y`, 65 bytes).
  """
  @spec normalize_public_key(binary()) :: {:ok, public_key()} | {:error, :bad_public_key}
  def normalize_public_key(<<0x04, x::binary-size(32), y::binary-size(32)>> = key) do
    # Curve membership: OTP rejects off-curve points on verify; still refuse
    # the all-zero / obviously malformed coordinates early.
    if x == <<0::256>> or y == <<0::256>> do
      {:error, :bad_public_key}
    else
      {:ok, key}
    end
  end

  def normalize_public_key(_), do: {:error, :bad_public_key}

  @doc """
  Verifies a WebCrypto ECDSA P-256 / SHA-256 signature in IEEE P1363 form
  (`r || s`, 64 bytes) over `signing_input(conn_id, challenge)`.
  """
  @spec verify_signature(public_key(), term(), challenge(), binary()) ::
          :ok | {:error, :bad_signature | :bad_signature_encoding}
  def verify_signature(public_key, conn_id, challenge, signature)
      when byte_size(public_key) == 65 and byte_size(signature) == 64 and is_binary(challenge) do
    with {:ok, der} <- raw_to_der(signature) do
      input = signing_input(conn_id, challenge)

      if :crypto.verify(:ecdsa, :sha256, input, der, [public_key, :secp256r1]) do
        :ok
      else
        {:error, :bad_signature}
      end
    end
  rescue
    _ -> {:error, :bad_signature}
  end

  def verify_signature(_, _, _, _), do: {:error, :bad_signature_encoding}

  defp raw_to_der(<<r::unsigned-big-size(256), s::unsigned-big-size(256)>>) do
    {:ok, :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})}
  end

  defp raw_to_der(_), do: {:error, :bad_signature_encoding}
end
