defmodule AshA2A.SemanticWork.ExactSubjectTest do
  use ExUnit.Case, async: true
  alias AshA2A.SemanticWork.ExactSubject

  test "fails closed" do
    assert {:error, _} = ExactSubject.bind(%{})
    assert {:error, :refused_invalid_envelope} = ExactSubject.bind(:invalid)
  end
end
