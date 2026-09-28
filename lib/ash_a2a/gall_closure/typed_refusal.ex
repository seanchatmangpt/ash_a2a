defmodule AshA2A.GallClosure.TypedRefusal do
  @moduledoc "Bounded GALL-029/030 guard for refusal_code."
  def admit(%{refusal_code: v} = s) when v not in [nil, false, ""],
    do: {:ok, Map.put(s, :gall_guard, :typed_refusal)}

  def admit(_), do: {:error, :missing_refusal}
end
