defmodule AshA2A.GallClosure.PrimaryConsumer do
  @moduledoc "Bounded GALL-029/030 guard for primary_consumer."
  def admit(%{primary_consumer: v} = s) when v not in [nil, false, ""],
    do: {:ok, Map.put(s, :gall_guard, :primary_consumer)}

  def admit(_), do: {:error, :missing_primary_consumer}
end
