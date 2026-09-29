defmodule AshA2A.ExactSubjectTest do
  use ExUnit.Case, async: true

  test "refuses drift" do
    assert :ok = AshA2A.ConsequenceKernel.ExactSubject.bind("a", "a")

    assert {:error, :prepared_record_identity_mismatch} =
             AshA2A.ConsequenceKernel.ExactSubject.bind("a", "b")
  end
end
