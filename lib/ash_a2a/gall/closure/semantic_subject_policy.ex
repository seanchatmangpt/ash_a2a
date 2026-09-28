defmodule AshA2A.Gall.Closure.SemanticSubjectPolicy do
  @moduledoc "Requires the candidate semantic subject to be present in the explicitly admitted subject set."

  def admit(candidate, allowed) when is_map(candidate) and is_list(allowed) do
    subject = field(candidate, :semantic_subject_digest)

    if subject in allowed,
      do: {:ok, candidate},
      else: {:error, {:refused_gall, :semantic_subject_policy, {:subject_not_admitted, subject}}}
  end

  def admit(_, _), do: {:error, {:refused_gall, :semantic_subject_policy, :invalid_policy}}

  defp field(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end
