defmodule AshA2A.Semantic.InterchangeRuntimeIdentityTest do
  use ExUnit.Case, async: true
  test "runtime field is retained" do
    b = struct(AshA2A.Semantic.InterchangeBoundary, runtime: :beam)
    assert b.runtime == :beam
  end
end
