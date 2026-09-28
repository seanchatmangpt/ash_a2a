defmodule AshA2A.GallClosure.Determinism do
  @moduledoc "Bounded GALL-029/030 guard for seed."
  def admit(%{seed: v} = s) when v not in [nil, false, ""],
    do: {:ok, Map.put(s, :gall_guard, :determinism)}

  def admit(_), do: {:error, :missing_seed}
end
