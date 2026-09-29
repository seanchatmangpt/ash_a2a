defmodule AshA2A.ConsequenceKernel.PreparedEffectStore do
  @moduledoc """
  Durable journal contract for the C1 PreparedEffect boundary.

  Implementations own authenticated prepared records plus request/effect claims.
  The public helpers normalize pid-backed stores and module-backed durable stores
  behind one production-facing contract.
  """

  alias AshA2A.ConsequenceKernel.PreparedEffectStore.AuthenticatedRecord

  @callback put(term(), map()) :: :ok | {:error, term()}
  @callback fetch(term(), binary()) :: {:ok, map()} | :not_found | {:error, term()}
  @callback transition(term(), binary(), atom(), atom()) :: :ok | {:error, term()}
  @callback claim_request(term(), binary(), term()) :: :ok | {:error, term()}
  @callback claim_effect(term(), binary(), term()) :: :ok | {:error, term()}
  @callback complete(term(), binary(), term()) :: :ok | {:error, term()}

  def prepare(store, prepared, opts) do
    provider = Keyword.fetch!(opts, :key_provider)
    key_opts = Keyword.get(opts, :key_opts, [])

    with {:ok, record} <- AuthenticatedRecord.seal(prepared, provider, key_opts) do
      case call(store, :put, [record]) do
        :ok -> :ok
        {:error, :prepared_duplicate} -> verify_existing(store, prepared.prepared_digest, provider, key_opts)
        other -> other
      end
    end
  end

  def claim_request(store, id, owner), do: call(store, :claim_request, [id, owner])
  def claim_effect(store, id, owner), do: call(store, :claim_effect, [id, owner])
  def transition(store, digest, from, to), do: call(store, :transition, [digest, from, to])
  def complete(store, digest, outcome, _opts), do: call(store, :complete, [digest, outcome])

  defp verify_existing(store, digest, provider, key_opts) do
    with {:ok, record} <- call(store, :fetch, [digest]),
         :ok <- AuthenticatedRecord.verify(record, provider, key_opts),
         true <- record.digest == digest do
      :ok
    else
      false -> {:error, :prepared_digest_mismatch}
      :not_found -> {:error, :prepared_record_missing}
      {:error, _} = error -> error
    end
  end

  defp call({module, handle}, fun, args) when is_atom(module),
    do: apply(module, fun, [handle | args])

  defp call(module, fun, args) when is_atom(module),
    do: apply(module, fun, args)

  defp call(pid, fun, args) when is_pid(pid),
    do: apply(AshA2A.ConsequenceKernel.PreparedEffectStore.Memory, fun, [pid | args])
end
