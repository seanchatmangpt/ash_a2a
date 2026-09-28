defmodule AshA2A.GallClosure.Idempotency do
  @moduledoc "Bounded GALL-029/030 guard for idempotency_key."
  def admit(%{idempotency_key: v}=s) when v not in [nil,false,""], do: {:ok, Map.put(s,:gall_guard,:idempotency)}
  def admit(_), do: {:error,:missing_idempotency}
end
