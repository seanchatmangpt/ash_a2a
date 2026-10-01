defmodule AshA2A.Semantic.InterchangeDistinctFieldsTest do
  use ExUnit.Case, async: true
  test "subject differs from runtime" do
    b = struct(AshA2A.Semantic.InterchangeBoundary, subject: :source, runtime: :host)
    assert b.subject != b.runtime
  end
end
