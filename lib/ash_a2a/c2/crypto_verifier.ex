# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C2.CryptoVerifier do
  @moduledoc """
  Primitive verification for the C2 kernel. Suite atoms map to registry suite ids and, for
  the post-quantum placeholders, to the real OTP `:crypto` atoms:

    * `:es256` -> `"ES256"` (strict X9.62 DER), `:eddsa` -> `"EdDSA"`
    * `:ml_dsa` -> `:mldsa65`, `:ml_dsa_44`/`:ml_dsa_65`/`:ml_dsa_87`
    * `:slh_dsa` -> `:slh_dsa_sha2_128s`

  Returns `true` on a valid signature; every failure is a typed `{:error, code}`
  (`:bad_signature`, `:bad_key`, `:provider_required` when the OTP atom is absent,
  `:unsupported_algorithm`) and nothing raises on hostile input.
  """
  alias Sa2aCrypto.Native

  @suites %{
    es256: {"ES256", nil},
    eddsa: {"EdDSA", nil},
    ml_dsa: {"ML-DSA-65", :mldsa65},
    ml_dsa_44: {"ML-DSA-44", :mldsa44},
    ml_dsa_65: {"ML-DSA-65", :mldsa65},
    ml_dsa_87: {"ML-DSA-87", :mldsa87},
    slh_dsa: {"SLH-DSA-SHA2-128S", :slh_dsa_sha2_128s}
  }

  def supported?(a), do: Map.has_key?(@suites, a)

  @doc "Real OTP `:crypto` atom behind a placeholder (`nil` for the classical suites)."
  def otp_atom(a) do
    case Map.fetch(@suites, a) do
      {:ok, {_, atom}} -> atom
      :error -> nil
    end
  end

  @doc "Registry suite id for a suite atom."
  def suite_id(a) do
    case Map.fetch(@suites, a) do
      {:ok, {id, _}} -> id
      :error -> nil
    end
  end

  def verify(alg, msg, sig, pub) do
    case Map.fetch(@suites, alg) do
      {:ok, {id, _}} ->
        case Native.verify(id, msg, sig, pub) do
          :ok -> true
          {:error, _} = e -> e
        end

      :error ->
        {:error, :unsupported_algorithm}
    end
  end
end
