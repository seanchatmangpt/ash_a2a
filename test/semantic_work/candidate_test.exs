# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticWork.CandidateTest do
  use ExUnit.Case, async: true
  alias AshA2A.SemanticWork.Candidate

  test "requires subject-bound input" do
    assert {:error, _} = Candidate.bind(%{})
    assert {:error, :refused_invalid_envelope} = Candidate.bind(nil)
  end
end
