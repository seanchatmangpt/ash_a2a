# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.SubjectLineage do
  def same?(%{semantic_subject: a}, %{semantic_subject: b}), do: same?(a, b)

  def same?(%{projection_digest: a}, %{projection_digest: b})
      when not is_nil(a) and not is_nil(b), do: a == b

  def same?(a, b), do: a == b
  def guard(a, b), do: if(same?(a, b), do: :ok, else: {:error, %{code: :replan_subject_drift}})
end
