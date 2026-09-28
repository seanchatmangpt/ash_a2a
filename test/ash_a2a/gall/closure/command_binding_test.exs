defmodule AshA2A.Gall.Closure.CommandBindingTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.CommandBinding

  test "command binds exact capability and candidate digest" do
    candidate = %{capability_id: "Item.create", candidate_digest: "sha256:" <> String.duplicate("a", 64)}
    command = %{capability_id: "Item.create", metadata: %{gall_029_candidate_digest: candidate.candidate_digest}}
    assert {:ok, ^command} = CommandBinding.admit(candidate, command)

    assert {:error, {:refused_gall, :command_binding, :candidate_digest_mismatch}} =
             CommandBinding.admit(candidate, put_in(command, [:metadata, :gall_029_candidate_digest], "wrong"))
  end
end
