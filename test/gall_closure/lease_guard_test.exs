defmodule AshA2A.GallClosure.LeaseGuardTest do
  use ExUnit.Case, async: true
  alias AshA2A.GallClosure.LeaseGuard

  test "bounded admission",
    do: assert(match?({:ok, _}, LeaseGuard.admit(%{lease_epoch: 7})))

  test "typed refusal", do: assert(LeaseGuard.admit(%{}) == {:error, :missing_lease})

  test "admits zero and positive epochs with guard tag" do
    assert {:ok, %{gall_guard: :lease_guard}} = LeaseGuard.admit(%{lease_epoch: 0})
    assert {:ok, _} = LeaseGuard.admit(%{lease_epoch: 42})
  end

  test "refuses negative and non-integer epochs" do
    for v <- [-1, "witness", "1", 1.0, true, nil, false, ""] do
      assert LeaseGuard.admit(%{lease_epoch: v}) == {:error, :missing_lease}
    end
  end
end
