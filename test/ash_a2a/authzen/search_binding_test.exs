defmodule AshA2A.AuthZEN.SearchBindingTest do
  use ExUnit.Case, async: true
  alias AshA2A.AuthZEN.SearchBinding

  test "pagination preserves the initial request identity" do
    initial = %{"subject" => %{"type" => "user"}, "resource" => %{"type" => "doc"}}
    assert {:ok, state} = SearchBinding.start(initial)
    assert {:ok, state} = SearchBinding.next(state, initial, "page-2")
    assert state.page_token == "page-2"

    mutated = put_in(initial, ["resource", "type"], "payment")
    assert {:error, :pagination_request_mutated} =
             SearchBinding.next(state, mutated, "page-3")
  end
end
