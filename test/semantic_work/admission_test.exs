defmodule AshA2A.SemanticWork.AdmissionTest do
  use ExUnit.Case, async: true
  alias AshA2A.SemanticWork.Admission

  test "requires subject-bound input" do
    assert {:error, _} = Admission.bind(%{})
    assert {:error, :refused_invalid_envelope} = Admission.bind(nil)
  end
end
