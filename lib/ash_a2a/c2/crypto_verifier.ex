defmodule AshA2A.C2.CryptoVerifier do
  @moduledoc "Algorithm-agile signature verification. PQ algorithms require an injected mature provider."
  @algs [:eddsa, :ml_dsa, :slh_dsa]
  def supported?(a), do: a in @algs
  def verify(:eddsa, msg, sig, pub, _provider \\ nil), do: :crypto.verify(:eddsa, :none, msg, sig, [pub, :ed25519])
  def verify(a, msg, sig, pub, provider) when a in [:ml_dsa, :slh_dsa] and is_atom(provider),
    do: provider.verify(a, msg, sig, pub)
  def verify(a, _, _, _, nil) when a in [:ml_dsa, :slh_dsa], do: {:error, :provider_required}
  def verify(_, _, _, _, _), do: {:error, :unsupported_algorithm}
end
