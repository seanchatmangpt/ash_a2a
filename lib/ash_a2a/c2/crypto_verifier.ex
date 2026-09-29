defmodule AshA2A.C2.CryptoVerifier do
  @algs [:eddsa, :ml_dsa, :slh_dsa]
  def supported?(a), do: a in @algs
  def verify(:eddsa, msg, sig, pub), do: :crypto.verify(:eddsa, :none, msg, sig, [pub, :ed25519])
  def verify(a, _, _, _) when a in [:ml_dsa, :slh_dsa], do: {:error, :provider_required}
  def verify(_, _, _, _), do: {:error, :unsupported_algorithm}
end
