defmodule AshA2A.AuthZEN.DecisionGateTest do
  use ExUnit.Case, async: true
  alias AshA2A.AuthZEN.{DecisionGate, PolicyEvidence}
  alias AshA2A.C2.PreparedEffect

  defp evidence(effect, overrides \\ %{}) do
    struct!(PolicyEvidence, Map.merge(%{
      decision: true,
      policy_decision_point: "https://pdp.example",
      principal: effect.principal,
      effect_digest: effect.digest,
      observed_at: 1,
      context: %{}
    }, overrides))
  end

  test "allow is evidence only and must bind exact effect" do
    effect = PreparedEffect.new("principal:alice", :payments, %{"id" => 1}, %{})
    assert :ok = DecisionGate.admit(evidence(effect), effect, "https://pdp.example")
    assert {:error, :effect_digest_mismatch} =
             DecisionGate.admit(evidence(effect, %{effect_digest: "sha256:wrong"}), effect, "https://pdp.example")
  end

  test "denial remains denial" do
    effect = PreparedEffect.new("principal:alice", :payments, %{"id" => 1}, %{})
    assert {:error, :denied} =
             DecisionGate.admit(evidence(effect, %{decision: false}), effect, "https://pdp.example")
  end
end
