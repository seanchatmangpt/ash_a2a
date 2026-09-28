defmodule AshA2A.Gall.Closure.ExactSubject do
  @moduledoc "Validates exact repository/SHA, semantic subject and candidate identity before GALL closure."

  @sha ~r/\A[0-9a-f]{40}\z/
  @digest ~r/\Asha256:[0-9a-f]{64}\z/

  def admit(candidate) when is_map(candidate) do
    with repo when is_binary(repo) <- field(candidate, :producer_repository),
         true <- valid_repo?(repo),
         sha when is_binary(sha) <- field(candidate, :producer_sha),
         true <- Regex.match?(@sha, sha),
         subject when is_binary(subject) <- field(candidate, :semantic_subject_digest),
         true <- Regex.match?(@digest, subject),
         identity when is_binary(identity) <- field(candidate, :candidate_digest),
         true <- Regex.match?(@digest, identity) do
      {:ok,
       %{repository: repo, sha: sha, semantic_subject_digest: subject, candidate_digest: identity}}
    else
      _ -> {:error, {:refused_gall, :exact_subject, :invalid_or_inexact_subject}}
    end
  end

  def admit(_), do: {:error, {:refused_gall, :exact_subject, :invalid_envelope}}

  defp valid_repo?(repo) do
    case String.split(repo, "/", parts: 3) do
      [owner, name] -> owner != "" and name != ""
      _ -> false
    end
  end

  defp field(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end
