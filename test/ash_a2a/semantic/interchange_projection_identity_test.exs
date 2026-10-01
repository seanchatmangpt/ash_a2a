defmodule AshA2A.Semantic.InterchangeProjectionIdentityTest do
  use ExUnit.Case, async: true
  test "projection field is retained" do
    b = struct(AshA2A.Semantic.InterchangeBoundary, projection: :wasm)
    assert b.projection == :wasm
  end
end
