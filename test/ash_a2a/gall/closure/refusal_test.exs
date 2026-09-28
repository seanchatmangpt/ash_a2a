defmodule AshA2A.Gall.Closure.RefusalTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.Refusal

  test "typed refusal never invents retry or standing" do
    refusal = Refusal.normalize({:refused_gall, :scope_policy, :input_digest_mismatch})
    assert refusal.status == :refused
    assert refusal.boundary == :scope_policy
    assert refusal.retry == false
    assert refusal.standing == :refused
  end
end
