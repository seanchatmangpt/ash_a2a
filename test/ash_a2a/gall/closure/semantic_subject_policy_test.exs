# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.SemanticSubjectPolicyTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.SemanticSubjectPolicy

  test "semantic subject must match an admitted exact digest" do
    digest = "sha256:" <> String.duplicate("a", 64)
    candidate = %{semantic_subject_digest: digest}
    assert {:ok, ^candidate} = SemanticSubjectPolicy.admit(candidate, [digest])

    assert {:error, {:refused_gall, :semantic_subject_policy, {:subject_not_admitted, ^digest}}} =
             SemanticSubjectPolicy.admit(candidate, [])
  end
end
