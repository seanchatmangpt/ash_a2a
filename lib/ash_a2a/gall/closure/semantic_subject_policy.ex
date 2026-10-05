# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.SemanticSubjectPolicy do
  @moduledoc "Requires the candidate semantic subject to be present in the explicitly admitted subject set."

  def admit(candidate, allowed) when is_map(candidate) and is_list(allowed) do
    subject = AshA2A.Gall.Fields.get(candidate, :semantic_subject_digest)

    if subject in allowed,
      do: {:ok, candidate},
      else: {:error, {:refused_gall, :semantic_subject_policy, {:subject_not_admitted, subject}}}
  end

  def admit(_, _), do: {:error, {:refused_gall, :semantic_subject_policy, :invalid_policy}}
end
