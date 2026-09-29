defmodule AshA2A.Identity.Canonical.Normalizer do
  @moduledoc false
  alias AshA2A.Identity.Canonical.Encodable
  def normalize(v), do: with(:ok <- Encodable.validate(v), do: walk(v))
  defp walk(v) when is_map(v), do: v |> Enum.map(fn {k,x}->{to_string(k),unwrap(walk(x))} end) |> Map.new() |> then(&{:ok,&1})
  defp walk(v) when is_list(v), do: v |> Enum.map(&unwrap(walk(&1))) |> then(&{:ok,&1})
  defp walk(v), do: {:ok,v}
  defp unwrap({:ok,v}), do: v
end
