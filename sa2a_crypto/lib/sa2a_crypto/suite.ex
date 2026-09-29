defmodule Sa2aCrypto.Suite do
  @moduledoc """
  Closed, versioned suite registry (RFC-SA2A-007 E-E) and CryptoProfile rules.

  Profiles are ordered `:classical < :hybrid < :pqc`. A required profile of
  `:classical` accepts anything; `:hybrid` accepts hybrid and pqc envelopes;
  `:pqc` accepts pqc only. Consequently a `:hybrid`/`:pqc` requirement refuses
  a classical-only envelope (downgrade).
  """

  @classical ["ES256", "EdDSA"]
  @mldsa %{"ML-DSA-44" => :mldsa44, "ML-DSA-65" => :mldsa65, "ML-DSA-87" => :mldsa87}
  @slh %{
    "SLH-DSA-SHA2-128S" => :slh_dsa_sha2_128s,
    "SLH-DSA-SHA2-128F" => :slh_dsa_sha2_128f,
    "SLH-DSA-SHA2-192S" => :slh_dsa_sha2_192s,
    "SLH-DSA-SHA2-192F" => :slh_dsa_sha2_192f,
    "SLH-DSA-SHA2-256S" => :slh_dsa_sha2_256s,
    "SLH-DSA-SHA2-256F" => :slh_dsa_sha2_256f,
    "SLH-DSA-SHAKE-128S" => :slh_dsa_shake_128s,
    "SLH-DSA-SHAKE-128F" => :slh_dsa_shake_128f,
    "SLH-DSA-SHAKE-192S" => :slh_dsa_shake_192s,
    "SLH-DSA-SHAKE-192F" => :slh_dsa_shake_192f,
    "SLH-DSA-SHAKE-256S" => :slh_dsa_shake_256s,
    "SLH-DSA-SHAKE-256F" => :slh_dsa_shake_256f
  }
  @pqc Map.merge(@mldsa, @slh)

  @type profile :: :classical | :hybrid | :pqc
  @profiles [:classical, :hybrid, :pqc]

  @doc "OTP `:crypto` atom for a PQ suite id."
  @spec pq_atom(String.t()) :: atom() | nil
  def pq_atom(alg), do: Map.get(@pqc, alg)

  @doc "Classical suite ids."
  def classical_algs, do: @classical

  @doc "PQ suite ids."
  def pqc_algs, do: Map.keys(@pqc)

  @doc "Splits a hybrid id `\"ES256+ML-DSA-65\"` into `{classical, pqc}`."
  @spec hybrid_parts(String.t()) :: {:ok, {String.t(), String.t()}} | :error
  def hybrid_parts(alg) when is_binary(alg) do
    case String.split(alg, "+") do
      [c, p] when c in @classical ->
        if Map.has_key?(@pqc, p), do: {:ok, {c, p}}, else: :error

      _ ->
        :error
    end
  end

  def hybrid_parts(_), do: :error

  @doc "Profile a registered suite belongs to, or `nil` if unregistered."
  @spec profile_of(term()) :: profile() | nil
  def profile_of(alg) when alg in @classical, do: :classical

  def profile_of(alg) when is_binary(alg) do
    cond do
      Map.has_key?(@pqc, alg) -> :pqc
      match?({:ok, _}, hybrid_parts(alg)) -> :hybrid
      true -> nil
    end
  end

  def profile_of(_), do: nil

  @spec profiles() :: [profile()]
  def profiles, do: @profiles

  @doc "Does an envelope of profile `have` satisfy a requirement of `required`?"
  @spec satisfies?(profile(), profile()) :: boolean()
  def satisfies?(have, required) when have in @profiles and required in @profiles do
    rank(have) >= rank(required)
  end

  def satisfies?(_, _), do: false

  defp rank(:classical), do: 0
  defp rank(:hybrid), do: 1
  defp rank(:pqc), do: 2
end
