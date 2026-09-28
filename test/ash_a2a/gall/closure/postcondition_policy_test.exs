defmodule AshA2A.Gall.Closure.PostconditionPolicyTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.PostconditionPolicy

  test "postcondition requires independent exact-subject verification" do
    expected = %{item_exists: true}
    assert {:ok, bound} = PostconditionPolicy.bind(expected)

    observation = %{
      independent: true,
      status: :verified,
      expected_postcondition_digest: bound.digest
    }

    assert {:ok, ^observation} = PostconditionPolicy.verify(bound, observation)

    assert {:error, {:refused_gall, :postcondition_policy, :observer_not_independent}} =
             PostconditionPolicy.verify(bound, Map.put(observation, :independent, false))
  end
end
