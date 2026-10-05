# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.ExactSubject do
  @moduledoc "Validates exact repository/SHA, semantic subject and candidate identity before GALL closure."

  @sha ~r/\A[0-9a-f]{40}\z/
  @digest ~r/\Asha256:[0-9a-f]{64}\z/

  def admit(candidate) when is_map(candidate) do
    with repo when is_binary(repo) <- AshA2A.Gall.Fields.get(candidate, :producer_repository),
         true <- valid_repo?(repo),
         sha when is_binary(sha) <- AshA2A.Gall.Fields.get(candidate, :producer_sha),
         true <- Regex.match?(@sha, sha),
         subject when is_binary(subject) <-
           AshA2A.Gall.Fields.get(candidate, :semantic_subject_digest),
         true <- Regex.match?(@digest, subject),
         identity when is_binary(identity) <- AshA2A.Gall.Fields.get(candidate, :candidate_digest),
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
end
