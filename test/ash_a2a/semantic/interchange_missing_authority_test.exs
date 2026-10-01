defmodule AshA2A.Semantic.InterchangeMissingAuthorityTest do
  use ExUnit.Case, async: true
  test "missing runtime authority" do
    refute AshA2A.Semantic.InterchangeBoundary.authorized?(%AshA2A.Semantic.InterchangeBoundary{})
  end
end
