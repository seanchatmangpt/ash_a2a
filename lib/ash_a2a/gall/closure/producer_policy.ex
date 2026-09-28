defmodule AshA2A.Gall.Closure.ProducerPolicy do
  @moduledoc "Pins each admitted producer repository to one exact source SHA."

  def admit(candidate, allowed) when is_map(candidate) and is_map(allowed) do
    repo = field(candidate, :producer_repository)
    sha = field(candidate, :producer_sha)

    case Map.fetch(allowed, repo) do
      {:ok, ^sha} ->
        {:ok, candidate}

      {:ok, expected} ->
        {:error, {:refused_gall, :producer_policy, {:sha_mismatch, expected, sha}}}

      :error ->
        {:error, {:refused_gall, :producer_policy, {:repository_not_admitted, repo}}}
    end
  end

  def admit(_, _), do: {:error, {:refused_gall, :producer_policy, :invalid_policy}}

  defp field(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end
