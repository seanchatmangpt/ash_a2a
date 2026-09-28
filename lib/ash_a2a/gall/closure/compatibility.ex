defmodule AshA2A.Gall.Closure.Compatibility do
  @moduledoc "Fail-closed representation compatibility gate for GALL closure artifacts."

  @supported ["ash_a2a.gall.closure/v1"]

  def admit(%{"schema_version" => version} = artifact) when version in @supported,
    do: {:ok, artifact}

  def admit(%{schema_version: version} = artifact) when version in @supported,
    do: {:ok, artifact}

  def admit(artifact) when is_map(artifact) do
    version = Map.get(artifact, :schema_version) || Map.get(artifact, "schema_version")
    {:error, {:refused_gall, :compatibility, {:unsupported_version, version}}}
  end

  def admit(_), do: {:error, {:refused_gall, :compatibility, :invalid_artifact}}
end
