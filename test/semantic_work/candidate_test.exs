defmodule AshA2A.SemanticWork.CandidateTest do
  use ExUnit.Case, async: true
  alias AshA2A.SemanticWork.Candidate

  test "requires subject-bound input" do
    assert {:error, _} = Candidate.bind(%{})
    assert {:error, :refused_invalid_envelope} = Candidate.bind(nil)
  end
end
