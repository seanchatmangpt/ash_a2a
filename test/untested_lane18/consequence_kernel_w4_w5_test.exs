defmodule AshA2A.UntestedLane18.ConsequenceKernelW4W5Test do
  use ExUnit.Case, async: true

  alias AshA2A.ConsequenceKernel.W4.{
    ArchitecturePolicy,
    ConsequenceGate,
    EffectRequest,
    EffectorToken,
    ResolvedEffect
  }

  alias AshA2A.ConsequenceKernel.W4B.{
    BypassClassification,
    CallPathPolicy,
    MediationReceipt,
    MigrationRegistry,
    RawEffectGuard,
    UnknownOutcomePolicy
  }

  alias AshA2A.ConsequenceKernel.W5.{ClaimFence, CrashWindow, IndependentClaim}

  test "W4 EffectorToken mint requires binaries" do
    t = EffectorToken.mint("subj", "dig")
    assert %EffectorToken{exact_subject: "subj", prepared_digest: "dig"} = t
    assert_raise FunctionClauseError, fn -> EffectorToken.mint(:a, "d") end
  end

  test "W4 ArchitecturePolicy flags forbidden raw-effect tokens in source" do
    clean = "defmodule A do\n  def f, do: AshA2A.ConsequenceKernel.go()\nend"
    assert [] = ArchitecturePolicy.violations(clean)

    dirty = "x = Ash.create(r)\nAshA2A.Dispatcher.dispatch(c)\nAsh.destroy(y)"

    assert Enum.sort(ArchitecturePolicy.violations(dirty)) ==
             Enum.sort(["Ash.create(", "AshA2A.Dispatcher.dispatch(", "Ash.destroy("])

    assert ArchitecturePolicy.forbidden_tokens() |> length() == 4
  end

  test "W4 structs enforce required keys and default optional ones" do
    req = %EffectRequest{skill: "s", message: "m", resource_or_domain: :d, consequence: :change}
    assert req.history == [] and req.auth_identity == nil
    assert_raise ArgumentError, fn -> struct!(EffectRequest, skill: "s") end
    re = %ResolvedEffect{request: req, route: :consequence}
    assert re.exact_subject == nil and re.prepared_digest == nil
    assert_raise ArgumentError, fn -> struct!(ResolvedEffect, request: req) end
  end

  test "W4 ConsequenceGate admits only consequences" do
    assert :ok = ConsequenceGate.admit(:change)
    assert :ok = ConsequenceGate.admit(:external_do)
    assert {:error, :not_consequential} = ConsequenceGate.admit(:observe)
    assert {:error, :consequence_unclassified} = ConsequenceGate.admit(:weird)
  end

  describe "W4B" do
    test "RawEffectGuard" do
      assert :ok = RawEffectGuard.admit(%{consequence: :change, fence: true})
      assert :ok = RawEffectGuard.admit(%{consequence: :external_do, fence: true})
      assert :ok = RawEffectGuard.admit(%{consequence: :observe, observation_only: true})

      assert {:error, :raw_effect_path} =
               RawEffectGuard.admit(%{consequence: :change, fence: false})

      assert {:error, :raw_effect_path} = RawEffectGuard.admit(%{consequence: :change})
      assert {:error, :raw_effect_path} = RawEffectGuard.admit(%{consequence: :observe})
      assert {:error, :consequence_unclassified} = RawEffectGuard.admit(%{consequence: :unknown})
    end

    test "BypassClassification" do
      assert BypassClassification.classify(:observe) == :non_consequential
      assert BypassClassification.classify(:change) == :consequential
      assert BypassClassification.classify(:external_do) == :consequential
      assert BypassClassification.classify(:zzz) == :unclassified
    end

    test "MigrationRegistry" do
      assert {:ok, :kernel} = MigrationRegistry.target(:command_bus_change)
      assert {:ok, :dispatch_observe} = MigrationRegistry.target(:agent_observe)
      assert :error = MigrationRegistry.target(:other)
      assert map_size(MigrationRegistry.entries()) == 3
    end

    test "MediationReceipt" do
      a = MediationReceipt.admitted(:change, :kernel)
      assert a.admitted and a.refusal == nil
      r = MediationReceipt.refused(:change, :raw, :raw_effect_path)
      refute r.admitted
      assert r.refusal == :raw_effect_path
    end

    test "UnknownOutcomePolicy never permits blind retry" do
      assert {:error, :reconciliation_required} =
               UnknownOutcomePolicy.next(:unknown_outcome, :retry)

      assert {:ok, :reconcile} = UnknownOutcomePolicy.next(:unknown_outcome, :reconcile)
      assert {:ok, :compensate} = UnknownOutcomePolicy.next(:unknown_outcome, :compensate)
      assert {:ok, :terminal} = UnknownOutcomePolicy.next(:completed, :retry)
      assert {:ok, :terminal} = UnknownOutcomePolicy.next(:failed, :anything)
      assert {:error, :invalid_outcome} = UnknownOutcomePolicy.next(:unknown_outcome, :bogus)
      assert {:error, :invalid_outcome} = UnknownOutcomePolicy.next(:applying, :reconcile)
    end

    test "CallPathPolicy" do
      assert :ok = CallPathPolicy.admit(:observe, :agent_observation)
      assert :ok = CallPathPolicy.admit(:observe, :kernel)
      assert :ok = CallPathPolicy.admit(:change, :kernel)
      assert :ok = CallPathPolicy.admit(:external_do, :kernel)
      assert {:error, :raw_effect_path} = CallPathPolicy.admit(:change, :agent_observation)
      assert {:error, :raw_effect_path} = CallPathPolicy.admit(:mystery, :kernel)
    end
  end

  describe "W5" do
    test "IndependentClaim requires distinct binary claims" do
      assert :ok = IndependentClaim.admit("r", "e")
      assert {:error, :independent_effect_claim_required} = IndependentClaim.admit("x", "x")
      assert {:error, :independent_effect_claim_required} = IndependentClaim.admit(1, "e")
    end

    test "ClaimFence" do
      ok = %{
        request_claim: "r",
        effect_claim: "e",
        prepared_digest: "p",
        claimed_prepared_digest: "p"
      }

      assert :ok = ClaimFence.admit(ok)

      assert {:error, :prepared_digest_mismatch} =
               ClaimFence.admit(%{ok | claimed_prepared_digest: "q"})

      assert {:error, :prepared_digest_mismatch} = ClaimFence.admit(%{ok | effect_claim: "r"})
      assert {:error, :claim_fence_refused} = ClaimFence.admit(%{})
    end

    test "CrashWindow classifies ambiguity as unknown_outcome" do
      assert CrashWindow.classify(:before_do) == :not_applied
      assert CrashWindow.classify(:after_do_before_receipt) == :unknown_outcome
      assert CrashWindow.classify(:after_receipt) == :recorded
      assert CrashWindow.classify(:never_heard_of_it) == :unknown_outcome
    end
  end
end
