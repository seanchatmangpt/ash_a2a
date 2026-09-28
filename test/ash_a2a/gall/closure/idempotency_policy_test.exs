defmodule AshA2A.Gall.Closure.IdempotencyPolicyTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.IdempotencyPolicy

  test "idempotency identity is derived from exact candidate identity" do
    digest = "sha256:" <> String.duplicate("a", 64)
    candidate = %{candidate_digest: digest}
    key = IdempotencyPolicy.key_for(digest)
    command = %{metadata: %{idempotency_key: key}}
    assert {:ok, ^command} = IdempotencyPolicy.admit(command, candidate)

    assert {:error, {:refused_gall, :idempotency_policy, {:key_mismatch, _, "other"}}} =
             IdempotencyPolicy.admit(%{metadata: %{idempotency_key: "other"}}, candidate)
  end
end
