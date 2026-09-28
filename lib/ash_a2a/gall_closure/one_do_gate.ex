defmodule AshA2A.GallClosure.OneDoGate do
  @moduledoc "Bounded GALL-029/030 guard for do_count: must be the integer 0 or 1."
  def admit(%{do_count: v} = s) when is_integer(v) and v in [0, 1],
    do: {:ok, Map.put(s, :gall_guard, :one_do_gate)}

  def admit(_), do: {:error, :invalid_do_count}
end
