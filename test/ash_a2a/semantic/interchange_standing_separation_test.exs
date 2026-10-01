defmodule AshA2A.Semantic.InterchangeStandingSeparationTest do
  use ExUnit.Case, async: true
  alias AshA2A.Semantic.InterchangeBoundary, as: B

  test "technical external and authority dimensions cannot collapse" do
    base = %{subject: "s", contract: "c", projection: "p", runtime: "r",
      technical_standing: "t", external_standing: "e", runtime_authority: "a"}
    assert B.admit?(struct!(B, base))
    refute B.admit?(struct!(B, %{base | external_standing: "t"}))
    refute B.admit?(struct!(B, %{base | runtime_authority: "t"}))
    refute B.admit?(struct!(B, %{base | runtime_authority: "e"}))
  end
end
