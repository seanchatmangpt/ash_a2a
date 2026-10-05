# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.Migration do
  @moduledoc "Migrates older GALL candidate maps into the closure-v1 representation without rewriting canonical source identity."

  @schema "ash_a2a.gall.closure/v1"

  def to_v1(candidate) when is_map(candidate) do
    with digest when is_binary(digest) <- AshA2A.Gall.Fields.get(candidate, :candidate_digest),
         repo when is_binary(repo) <- AshA2A.Gall.Fields.get(candidate, :producer_repository),
         sha when is_binary(sha) <- AshA2A.Gall.Fields.get(candidate, :producer_sha) do
      {:ok,
       candidate
       |> stringify_keys()
       |> Map.put_new("schema_version", @schema)
       |> Map.put_new("authority", "NONE")
       |> Map.put_new("standing", "CANDIDATE")
       |> Map.put("candidate_digest", digest)
       |> Map.put("producer_repository", repo)
       |> Map.put("producer_sha", sha)}
    else
      _ -> {:error, {:refused_gall, :migration, :missing_exact_identity}}
    end
  end

  def to_v1(_), do: {:error, {:refused_gall, :migration, :invalid_candidate}}

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
