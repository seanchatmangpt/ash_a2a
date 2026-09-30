defmodule AshA2A.AuthZEN.ProjectionTest do
  use ExUnit.Case, async: true
  alias AshA2A.AuthZEN.Projection
  alias AshA2A.C2.PreparedEffect

  test "projects exact principal capability and digest into SARC" do
    effect = PreparedEffect.new("principal:alice", :payments, %{"id" => 42}, %{"amount" => 100})
    assert {:ok, request} = Projection.from_effect(effect, %{"ip" => "127.0.0.1"})
    assert request.subject.id == "principal:alice"
    assert request.action.id == "payments"
    assert request.resource.id == effect.digest
    assert request.context["sa2a"]["effect_digest"] == effect.digest
    assert request.context["sa2a"]["principal"] == "principal:alice"
  end
end
