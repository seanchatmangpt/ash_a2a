defmodule AshA2A.GallClosure.AuthorityCeilingTest do
  use ExUnit.Case, async: true
  alias AshA2A.GallClosure.AuthorityCeiling

  test "bounded admission",
    do: assert(match?({:ok, _}, AuthorityCeiling.admit(%{authority: "witness"})))

  test "typed refusal", do: assert(AuthorityCeiling.admit(%{}) == {:error, :authority_exceeded})

  test "admits every ceiling member as string, atom, and mixed case" do
    for a <- ~w(none witness observe propose select) do
      assert {:ok, %{gall_guard: :authority_ceiling}} = AuthorityCeiling.admit(%{authority: a})
      assert {:ok, _} = AuthorityCeiling.admit(%{authority: String.to_atom(a)})
      assert {:ok, _} = AuthorityCeiling.admit(%{authority: String.upcase(a)})
    end
  end

  test "refuses authority above the ceiling" do
    for a <- ["execute", "do", "admin", "DO", :execute, :admin, "witness2", "", nil, false, 1] do
      assert AuthorityCeiling.admit(%{authority: a}) == {:error, :authority_exceeded}
    end
  end
end
