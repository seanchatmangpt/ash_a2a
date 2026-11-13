defmodule AshA2A.Protocol.Id.Generator do
  @moduledoc """
  Behaviour for pluggable protocol id generation.

  Configure with `config :ash_a2a, :id_generator, MyGenerator`. `kind` is the
  prefix string used by call sites (`"tsk"`, `"msg"`, `"art"`, ...); `ctx` is a
  map of caller context (empty when the call site supplies none).
  """

  @callback generate(kind :: String.t(), ctx :: map()) :: String.t()
end

defmodule AshA2A.Protocol.Id.Generator.Default do
  @moduledoc """
  Default generator: `"<kind>-<12 random alphanumerics>"`.
  """

  @behaviour AshA2A.Protocol.Id.Generator

  @alphabet Enum.concat([?0..?9, ?a..?z, ?A..?Z])
  @length 12

  @impl true
  def generate(kind, _ctx) do
    suffix =
      for _ <- 1..@length, into: "" do
        <<Enum.random(@alphabet)>>
      end

    "#{kind}-#{suffix}"
  end
end

defmodule AshA2A.Protocol.ID do
  @moduledoc false

  @doc """
  Generates a prefixed random ID (e.g., `"tsk-a1B2c3D4e5F6"`) through the
  configured `AshA2A.Protocol.Id.Generator` (`config :ash_a2a, :id_generator`).
  """
  @spec generate(String.t()) :: String.t()
  def generate(prefix), do: generate(prefix, %{})

  @spec generate(String.t(), map()) :: String.t()
  def generate(prefix, ctx) do
    mod = Application.get_env(:ash_a2a, :id_generator) || AshA2A.Protocol.Id.Generator.Default
    mod.generate(prefix, ctx)
  end
end
