defmodule AshA2A.SemanticWork.IdempotencyTest do
  use ExUnit.Case, async: true
  alias AshA2A.SemanticWork.Idempotency

  test "requires subject-bound input" do
    assert {:error, _} = Idempotency.bind(%{})
    assert {:error, :refused_invalid_envelope} = Idempotency.bind(nil)
  end
end
