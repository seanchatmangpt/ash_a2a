defmodule AshA2A.Gall.Closure.AuthorityBindingTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.AuthorityBinding

  test "authority independently binds principal, capability, scope and one-DO budget" do
    scope = %{input_digest: "sha256:x"}
    command = %{principal_id: "p1", capability_id: "Item.create"}

    authority = %{
      subject: "p1",
      capability_id: "Item.create",
      constraints: %{scope: scope, max_consequences: 1}
    }

    assert {:ok, ^authority} = AuthorityBinding.admit(authority, command, scope, 1)

    bad = put_in(authority, [:constraints, :max_consequences], 2)

    assert {:error, {:refused_gall, :authority_binding, :budget_mismatch}} =
             AuthorityBinding.admit(bad, command, scope, 1)
  end
end
