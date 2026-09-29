defmodule AshA2A.C2.CertificateVerifier do
  alias AshA2A.C2.{CompleteMediation, CryptoVerifier}
  def verify(c, e, ctx) do
    msg = Map.fetch!(ctx, :certificate_message)
    keys = Map.fetch!(ctx, :verification_keys)
    provider = Map.get(ctx, :pq_provider)
    with :ok <- CompleteMediation.admit(e, c, ctx),
         true <- is_integer(c.threshold) and c.threshold > 0,
         {:ok, verified} <- verified_signers(c.signatures, msg, keys, provider),
         true <- MapSet.size(verified) >= c.threshold,
         do: :ok,
         else: (_ -> {:error, :certificate_refused})
  end
  defp verified_signers(signatures, msg, keys, provider) do
    Enum.reduce_while(signatures, {:ok, MapSet.new()}, fn s, {:ok, acc} ->
      with true <- CryptoVerifier.supported?(s.algorithm),
           {:ok, pub} <- Map.fetch(keys, s.signer),
           true <- CryptoVerifier.verify(s.algorithm, msg, s.signature, pub, provider) do
        {:cont, {:ok, MapSet.put(acc, s.signer)}}
      else
        _ -> {:halt, {:error, :signature_refused}}
      end
    end)
  end
end
