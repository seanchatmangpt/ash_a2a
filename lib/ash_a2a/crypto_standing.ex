# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.CryptoStanding do
  @moduledoc """
  Thin adapter over the standalone `sa2a_crypto` project (`Sa2aCrypto.*`).

  SA2A never touches signature algorithms directly: it consumes cryptographic STANDING,
  `{:valid, %{kid, custodian_id, tier, epoch}} | {:invalid, refusal_code}`. Standing
  certifies; it NEVER authorizes an effect. Authorization is decided by SA2A/BRCE from
  standing plus policy plus authority (RFC-SA2A-007 E-E).
  """

  alias Sa2aCrypto.{Envelope, SignedMessage}

  @type standing :: Sa2aCrypto.Standing.t()

  @doc "Domain-separated signed bytes (`SA2A-C2-APPROVAL-v1 || 0x00 || JCS(...)`)."
  @spec signed_message(map()) :: {:ok, binary()} | {:error, atom()}
  defdelegate signed_message(fields), to: SignedMessage, as: :build

  @doc "Verify `envelope` over `message_bytes` against a registry view; returns standing."
  @spec verify(Envelope.t() | map(), binary(), {module(), term()}, keyword()) :: standing()
  defdelegate verify(envelope, message_bytes, registry_view, opts \\ []),
    to: Sa2aCrypto,
    as: :verify_envelope

  @doc "Replay key for a verified envelope: `{kid, nonce}`, never signature bytes."
  @spec replay_key(Envelope.t()) :: {String.t(), String.t()}
  defdelegate replay_key(envelope), to: Envelope

  @spec valid?(standing()) :: boolean()
  defdelegate valid?(standing), to: Sa2aCrypto.Standing
end
