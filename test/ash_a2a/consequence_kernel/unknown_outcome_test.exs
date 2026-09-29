defmodule AshA2A.UnknownOutcomeTest do
  use ExUnit.Case, async: true

  test "unknown retains effect identity" do
    p = %{instance: %{effect_id: "e"}, prepared_digest: "p"}
    x = AshA2A.ConsequenceKernel.UnknownOutcome.new(p, :ambiguous)
    assert x.effect_id == "e"
  end
end
