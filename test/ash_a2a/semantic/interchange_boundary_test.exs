defmodule AshA2A.Semantic.InterchangeBoundaryTest do
  use ExUnit.Case, async: true

  test "technical standing does not imply runtime authority" do
    attrs = %{subject: :s, contract: :c, projection: :p, runtime: :r, technical_standing: :admitted}
    assert {:ok, boundary} = AshA2A.Semantic.InterchangeBoundary.new(attrs)
    refute AshA2A.Semantic.InterchangeBoundary.authorized?(boundary)
  end
end
