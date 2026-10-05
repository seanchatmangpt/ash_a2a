defmodule AshA2A.Protocol.ID do
  @moduledoc false

  @alphabet Enum.concat([?0..?9, ?a..?z, ?A..?Z])
  @length 12

  @doc """
  Generates a prefixed random ID (e.g., `"tsk-a1B2c3D4e5F6"`).
  """
  @spec generate(String.t()) :: String.t()
  def generate(prefix) do
    suffix =
      for _ <- 1..@length, into: "" do
        <<Enum.random(@alphabet)>>
      end

    "#{prefix}-#{suffix}"
  end
end
