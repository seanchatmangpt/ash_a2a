defmodule AshA2A.ConsequenceKernel.PreparedEffectStore.AuthenticatedRecord do
  alias AshA2A.ConsequenceKernel.{KeyCustody, PreparedRecordCodec}
  def seal(prepared, provider, opts) do
    with {:ok, bytes} <- PreparedRecordCodec.encode(prepared),
         {:ok, tag} <- KeyCustody.mac(provider, bytes, opts) do
      {:ok, %{bytes: bytes, tag: tag, digest: prepared.prepared_digest, state: :prepared}}
    end
  end
  def verify(%{bytes: bytes, tag: tag}, provider, opts), do: KeyCustody.verify(provider, bytes, tag, opts)
end
