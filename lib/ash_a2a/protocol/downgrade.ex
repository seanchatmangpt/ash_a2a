defmodule AshA2A.Protocol.Downgrade do
  @moduledoc """
  Pure projection of v1.1 wire maps onto the v1.0 shape.

  v1.1-only fields are emitted only when the negotiated version is >= 1.1 or
  no `A2A-Version` header was sent (`nil`). An explicit version below 1.1 gets
  the pure 1.0 shape.
  """

  alias AshA2A.Protocol.Version

  @drop_keys ["generation", "timeline", "startGeneration", "endGeneration"]

  @doc "True iff `version` is a binary strictly below 1.1 (invalid => false)."
  @spec applies?(term()) :: boolean()
  def applies?(version) when is_binary(version) do
    case Regex.run(~r/^\s*\d+\.\d+/, version) do
      nil -> false
      _ -> not Version.at_least?(version, "1.1")
    end
  end

  def applies?(_), do: false

  @doc """
  True when the downgrade applies and `term` is a StreamResponse frame whose
  only top-level key is `"messageUpdate"` (directly, or inside a `"result"` /
  `"payload"` wrapper).
  """
  @spec drop_frame?(term(), term()) :: boolean()
  def drop_frame?(term, version), do: applies?(version) and message_update_frame?(term)

  defp message_update_frame?(%{"messageUpdate" => _} = m) when map_size(m) == 1, do: true

  defp message_update_frame?(%{"result" => inner}) when is_map(inner),
    do: message_update_frame?(inner)

  defp message_update_frame?(%{"payload" => inner}) when is_map(inner),
    do: message_update_frame?(inner)

  defp message_update_frame?(_), do: false

  @doc "Project `term` to the wire shape for `version`; may return `:drop` for a frame."
  @spec to_wire(term(), String.t() | nil) :: term()
  def to_wire(term, version) do
    cond do
      not applies?(version) -> term
      message_update_frame?(term) -> :drop
      true -> walk(term)
    end
  end

  defp walk(list) when is_list(list) do
    list
    |> Enum.reject(&message_update_frame?/1)
    |> Enum.map(&walk/1)
  end

  defp walk(%{} = map) when not is_struct(map) do
    artifact? = Map.has_key?(map, "artifactId")

    map
    |> Enum.reject(fn {k, _} -> k in @drop_keys or (artifact? and k == "role") end)
    |> Map.new(fn {k, v} -> {k, walk(v)} end)
  end

  defp walk(other), do: other
end
