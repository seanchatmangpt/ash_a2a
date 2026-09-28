defmodule AshA2A.GallClosure.IdempotencyTest do
 use ExUnit.Case, async: true
 alias AshA2A.GallClosure.Idempotency
 test "bounded admission", do: assert match?({:ok,_}, Idempotency.admit(%{idempotency_key: "witness"}))
 test "typed refusal", do: assert Idempotency.admit(%{}) == {:error,:missing_idempotency}
end
