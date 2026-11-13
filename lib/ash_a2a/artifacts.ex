defmodule AshA2A.Artifacts do
  @moduledoc """
  Multi-artifact return shape for a generic `:action` skill.

  A generic action may return `{:ok, %AshA2A.Artifacts{artifacts: [...]}}` to
  hand several named artifacts back from one dispatch. Each entry is either a
  list of `AshA2A.Protocol.Part` structs or a map with a `:parts` list (and
  optional `:name` / `:description`). See `AshA2A.Dispatcher` for the full
  return contract.
  """

  @type artifact ::
          [AshA2A.Protocol.Part.t()]
          | %{
              required(:parts) => [AshA2A.Protocol.Part.t()],
              optional(:name) => String.t(),
              optional(:description) => String.t()
            }

  @type t :: %__MODULE__{artifacts: [artifact()]}

  defstruct artifacts: []

  @doc """
  Flattens the artifacts to one ordered part list (the shape the current
  `{:reply, parts}` dispatch reply can carry).

      iex> AshA2A.Artifacts.parts(%AshA2A.Artifacts{artifacts: [[:a], %{parts: [:b, :c]}]})
      [:a, :b, :c]
  """
  @spec parts(t()) :: [AshA2A.Protocol.Part.t()]
  def parts(%__MODULE__{artifacts: artifacts}) do
    Enum.flat_map(artifacts, fn
      %{parts: parts} when is_list(parts) -> parts
      parts when is_list(parts) -> parts
      _other -> []
    end)
  end
end
