defmodule AshA2A.Gall.Closure.CommandBinding do
  @moduledoc "Binds a candidate to the exact command capability and candidate digest."

  def admit(candidate, command) when is_map(candidate) and is_map(command) do
    capability = field(candidate, :capability_id)
    digest = field(candidate, :candidate_digest)
    command_capability = field(command, :capability_id)
    metadata = field(command, :metadata) || %{}
    bound = field(metadata, :gall_029_candidate_digest) || field(metadata, :candidate_digest)

    cond do
      command_capability != capability ->
        {:error, {:refused_gall, :command_binding, :capability_mismatch}}

      bound != digest ->
        {:error, {:refused_gall, :command_binding, :candidate_digest_mismatch}}

      true ->
        {:ok, command}
    end
  end

  def admit(_, _), do: {:error, {:refused_gall, :command_binding, :invalid_command}}

  defp field(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end
