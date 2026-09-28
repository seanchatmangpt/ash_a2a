defmodule AshA2A.SemanticWork.ReplayTest do
  use ExUnit.Case, async: true
  alias AshA2A.SemanticWork.Replay

  test "fails closed" do
    assert {:error, _} = Replay.bind(%{})
    assert {:error, :refused_invalid_envelope} = Replay.bind(:invalid)
  end
end
