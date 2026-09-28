defmodule AshA2A.GallClosure.OneDoGate do
  @moduledoc "Bounded GALL-029/030 guard for do_count."
  def admit(%{do_count: v}=s) when v not in [nil,false,""], do: {:ok, Map.put(s,:gall_guard,:one_do_gate)}
  def admit(_), do: {:error,:invalid_do_count}
end
