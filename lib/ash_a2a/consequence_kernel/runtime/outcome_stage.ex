defmodule AshA2A.ConsequenceKernel.Runtime.OutcomeStage do
  alias AshA2A.ConsequenceKernel.Runtime.{PreparedDigest, StoreHandle}
  def persist(store, prepared, result) do
    with {:ok, digest} <- PreparedDigest.fetch(prepared), do: persist_digest(store, digest, result)
  end
  defp persist_digest(store, digest, {:ok, value}) do
    with :ok <- StoreHandle.call(store, :transition, [digest, :applying, :completed]), do: {:ok, value}
  end
  defp persist_digest(store, digest, {:unknown, reason}) do
    _ = StoreHandle.call(store, :transition, [digest, :applying, :unknown_outcome]); {:unknown, reason}
  end
  defp persist_digest(store, digest, {:error, reason}) do
    _ = StoreHandle.call(store, :transition, [digest, :applying, :unknown_outcome]); {:unknown, {:effector_error_after_apply_boundary, reason}}
  end
end
