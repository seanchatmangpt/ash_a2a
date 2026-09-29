defmodule AshA2A.Replan.Conformance do
  def check(candidate, subject) do
    with :ok <- AshA2A.Replan.CandidateFence.check(candidate),
         :ok <- AshA2A.Replan.SubjectLineage.guard(Map.get(candidate,:subject,subject),subject), do: :ok
  end
end