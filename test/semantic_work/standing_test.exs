defmodule AshA2A.SemanticWork.StandingTest do
  use ExUnit.Case, async: true
  alias AshA2A.SemanticWork.Standing

  test "requires subject-bound input" do
    assert {:error, _} = Standing.bind(%{})
    assert {:error, :refused_invalid_envelope} = Standing.bind(nil)
  end
end
