defmodule AshA2A.Semantic.InterchangeInvalidSubjectTest do
  use ExUnit.Case, async: true
  test "subject field is exact data" do
    b = struct(AshA2A.Semantic.InterchangeBoundary, subject: {:sha256, "abc"})
    assert b.subject == {:sha256, "abc"}
  end
end
