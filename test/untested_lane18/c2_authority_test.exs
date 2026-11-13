defmodule AshA2A.UntestedLane18.C2AuthorityTest do
  use ExUnit.Case, async: true

  alias AshA2A.C2.{
    BudgetLedger,
    ConfusedDeputy,
    ControlPlaneFence,
    EffectorRegistry,
    FencingToken,
    PolicyEpoch,
    Principal,
    ResourceEnvelope,
    RevocationEpoch
  }

  defmodule RealEffector do
    @behaviour AshA2A.C2.Effector
    def perform(effect), do: {:ok, effect.capability}
  end

  defp cert(overrides \\ %{}),
    do: Map.merge(%{generation: 5, policy_epoch: 3, revocation_epoch: 2, principal: "p1"}, overrides)

  describe "BudgetLedger" do
    test "allocate debits parent and yields child with limit" do
      assert {:ok, %{remaining: 6}, %{limit: 4, remaining: 4}} =
               BudgetLedger.allocate(%{remaining: 10, limit: 10}, 4)
    end

    test "refuses over-allocation, negatives and non-numbers" do
      b = %{remaining: 3}
      assert {:error, :budget_exceeded} = BudgetLedger.allocate(b, 4)
      assert {:error, :budget_exceeded} = BudgetLedger.allocate(b, -1)
      assert {:error, :budget_exceeded} = BudgetLedger.allocate(b, "1")
      assert {:error, :budget_exceeded} = BudgetLedger.allocate(%{}, 1)
    end

    test "exact exhaustion allowed then nothing left" do
      assert {:ok, %{remaining: 0} = b, _} = BudgetLedger.allocate(%{remaining: 3}, 3)
      assert {:error, :budget_exceeded} = BudgetLedger.allocate(b, 1)
    end

    test "conservation holds across successive allocations, fails when inflated" do
      parent = %{remaining: 10, limit: 10}
      {:ok, p1, c1} = BudgetLedger.allocate(parent, 4)
      {:ok, _p2, c2} = BudgetLedger.allocate(p1, 6)
      assert BudgetLedger.conserved?(parent, [c1, c2])
      refute BudgetLedger.conserved?(parent, [c1, c2, %{limit: 1}])
      assert BudgetLedger.conserved?(parent, [])
    end
  end

  describe "ConfusedDeputy" do
    test "refuses when requested principal differs from authenticated" do
      assert ConfusedDeputy.refuse?("alice", "bob")
      refute ConfusedDeputy.refuse?("alice", "alice")
    end
  end

  describe "ControlPlaneFence" do
    test "clean maps pass; atom and string forbidden keys fail" do
      assert ControlPlaneFence.clean?(%{"b" => 2, a: 1})
      assert ControlPlaneFence.clean?(%{})
      refute ControlPlaneFence.clean?(%{secret: 1})
      refute ControlPlaneFence.clean?(%{"private_key" => "x"})
      refute ControlPlaneFence.clean?(%{"password" => "x", ok: 1})
    end

    test "all forbidden names are refused in both key forms" do
      for k <- [:secret, :private_key, :access_token, :password, :credential] do
        refute ControlPlaneFence.clean?(%{k => 1})
        refute ControlPlaneFence.clean?(%{Atom.to_string(k) => 1})
      end
    end
  end

  describe "epochs and fencing" do
    test "fencing token is monotonic: older generation refused" do
      assert FencingToken.valid?(cert(), 5)
      assert FencingToken.valid?(cert(), 4)
      refute FencingToken.valid?(cert(), 6)
    end

    test "policy epoch must match exactly" do
      assert PolicyEpoch.valid?(cert(), 3)
      refute PolicyEpoch.valid?(cert(), 4)
      refute PolicyEpoch.valid?(cert(), 2)
    end

    test "revocation epoch must match exactly" do
      assert RevocationEpoch.valid?(cert(), 2)
      refute RevocationEpoch.valid?(cert(), 3)
    end

    test "non-integer current epoch has no clause (fail closed by FunctionClauseError)" do
      assert_raise FunctionClauseError, fn -> FencingToken.valid?(cert(), "5") end
      assert_raise FunctionClauseError, fn -> PolicyEpoch.valid?(cert(), nil) end
      assert_raise FunctionClauseError, fn -> RevocationEpoch.valid?(cert(), 2.0) end
    end
  end

  describe "ResourceEnvelope" do
    test "bound only when principal, digest and generation all agree" do
      env = %ResourceEnvelope{principal: "p1", effect_digest: "d", budget: 1, generation: 5}
      effect = %{principal: "p1", digest: "d"}
      assert ResourceEnvelope.bound?(env, effect, cert())
      refute ResourceEnvelope.bound?(env, %{effect | principal: "p2"}, cert())
      refute ResourceEnvelope.bound?(env, %{effect | digest: "e"}, cert())
      refute ResourceEnvelope.bound?(env, effect, cert(%{generation: 6}))
    end

    test "enforce_keys are required" do
      assert_raise ArgumentError, fn -> struct!(ResourceEnvelope, principal: "p") end
    end
  end

  describe "EffectorRegistry" do
    test "fetches module for capability, refuses unknown and non-atom entries" do
      reg = %{"cap" => RealEffector, "bad" => "not-atom"}
      assert {:ok, RealEffector} = EffectorRegistry.fetch(%{capability: "cap"}, reg)
      assert {:error, :unknown_effector} = EffectorRegistry.fetch(%{capability: "nope"}, reg)
      assert_raise CaseClauseError, fn -> EffectorRegistry.fetch(%{capability: "bad"}, reg) end
    end

    test "resolved effector performs a real PreparedEffect" do
      effect = AshA2A.C2.PreparedEffect.new("p1", "cap", %{"s" => 1}, %{"x" => 2})
      {:ok, mod} = EffectorRegistry.fetch(effect, %{"cap" => RealEffector})
      assert {:ok, "cap"} = mod.perform(effect)
    end
  end

  describe "Principal" do
    test "preserved only when effect and cert principal equal caller" do
      assert Principal.preserved?(%{principal: "a"}, %{principal: "a"}, "a")
      refute Principal.preserved?(%{principal: "a"}, %{principal: "b"}, "a")
      refute Principal.preserved?(%{principal: "b"}, %{principal: "a"}, "a")
    end
  end
end
