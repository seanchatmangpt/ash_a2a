defmodule AshA2A.Identity.Canonical.Encodable do
  @moduledoc false
  @max_depth 64
  def validate(value), do: validate(value, 0)
  defp validate(_, d) when d > @max_depth, do: {:error, :canonical_depth_exceeded}
  defp validate(v, _) when is_nil(v) or is_boolean(v) or is_integer(v) or is_binary(v), do: :ok
  defp validate(v, d) when is_list(v), do: reduce(v, d + 1)
  defp validate(v, d) when is_map(v), do: with(:ok <- keys(v), do: reduce(Map.values(v), d + 1))
  defp validate(v, _) when is_float(v), do: {:error, :canonical_float_forbidden}
  defp validate(_, _), do: {:error, :canonical_type_forbidden}
  defp reduce(xs,d), do: Enum.reduce_while(xs,:ok,fn x,:ok -> case validate(x,d) do :ok -> {:cont,:ok}; e -> {:halt,e} end end)
  defp keys(m) do
    ks=Map.keys(m); names=Enum.map(ks,&to_string/1)
    cond do
      Enum.any?(ks,&(not (is_binary(&1) or is_atom(&1)))) -> {:error,:canonical_key_type_forbidden}
      length(names) != length(Enum.uniq(names)) -> {:error,:canonical_key_collision}
      true -> :ok
    end
  end
end
