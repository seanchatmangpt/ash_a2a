# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Test.Enterprise.MonotonicLedger do
  @moduledoc """
  Court fixture resource (FR-01.4): a real ETS-backed Ash resource whose two
  `:external_do` skills each CREATE a real ledger record, so "did this
  delegated capability actuate" is answered by an independent `Ash.read!`
  record read, never by an interaction assertion.
  """

  use Ash.Resource,
    domain: AshA2A.Test.Enterprise.MonotonicLedgerDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:note, :string, allow_nil?: true, public?: true)
    attribute(:principal, :string, allow_nil?: true, public?: true)
  end

  actions do
    defaults([:read])

    create :file_report do
      accept([:note, :principal])
    end

    create :file_admin_report do
      accept([:note, :principal])
    end
  end

  a2a do
    skill(:report, :file_report, consequence: :external_do)
    skill(:admin_report, :file_admin_report, consequence: :external_do)
  end
end

defmodule AshA2A.Test.Enterprise.MonotonicLedgerDomain do
  @moduledoc "Real fixture domain for `AshA2A.Test.Enterprise.MonotonicLedger`."

  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2A.Test.Enterprise.MonotonicLedger)
  end
end

defmodule AshA2A.Test.Enterprise.MonotonicLedgerAgent do
  @moduledoc "Real `AshA2A.Protocol.Agent` GenServer over `MonotonicLedger`."

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Enterprise.MonotonicLedger,
    name: "monotonic_ledger_agent"
end

defmodule AshA2A.Enterprise.MonotonicGrantTest do
  @moduledoc """
  FR-01.4 court -- monotonic grant narrowing for agent-spawned subtasks.

  Chicago discipline: real agents (`AshA2A.Test.Enterprise.MonotonicLedgerAgent`,
  a real `AshA2A.Protocol.Agent` GenServer), real broker grants
  (`AshA2A.Authority.Grant.grant/3` into the suite's real InMemory broker),
  zero mocks. Side effects are read off the real ETS ledger with an
  independent `Ash.read!`: a narrowed grant actuates for real and creates
  exactly one record; an escalation attempt fails closed and creates nothing.
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Authority.Grant
  alias AshA2A.AuthZEN.{DecisionGate, Monotonic, PolicyEvidence}
  alias AshA2A.C2.PreparedEffect
  alias AshA2A.Test.Enterprise.{MonotonicLedger, MonotonicLedgerAgent}

  @pdp "https://pdp.monotonic.test"

  setup do
    AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [MonotonicLedgerAgent])
    :ok
  end

  # Same canonicalization the real dispatch path uses: the broker grant (and
  # therefore the monotonic chain) is keyed on the canonical capability id,
  # not the bare wire selector.
  defp cap(selector) do
    {:ok, skill} = AshA2A.Info.skill(MonotonicLedger, selector)
    skill.id
  end

  defp subject(name), do: AshA2A.Identity.principal(name)

  defp grant!(principal, selector) do
    assert {:ok, _authority} = Grant.grant(subject(principal), cap(selector))
    :ok
  end

  defp dispatch(principal, selector, note) do
    message =
      data_message(%{"note" => note, "principal" => principal}, %{metadata: %{skill: selector}})

    assert {:ok, task} =
             MonotonicLedgerAgent.call(MonotonicLedgerAgent, message,
               metadata: %{"a2a.auth" => %{identity: principal}}
             )

    task
  end

  # The independent side-effect read: real records in the real ETS table,
  # filtered to this test's unique principal.
  defp ledger_for(principal) do
    MonotonicLedger
    |> Ash.read!()
    |> Enum.filter(&(&1.principal == principal))
  end

  defp policy_evidence(effect) do
    struct!(PolicyEvidence, %{
      decision: true,
      policy_decision_point: @pdp,
      principal: effect.principal,
      effect_digest: effect.digest,
      observed_at: System.system_time(),
      context: %{}
    })
  end

  describe "(a) narrowing holds across three delegation hops" do
    test "each hop's effective set is a subset of its parent; the narrowed child really actuates" do
      root_principal = "mono-a-root"
      grant!(root_principal, :report)
      grant!(root_principal, :admin_report)

      root_chain = Monotonic.root([cap(:report), cap(:admin_report)])

      assert {:ok, hop1} = Monotonic.delegate(root_chain, [cap(:report)])
      assert {:ok, hop2} = Monotonic.delegate(hop1, [cap(:report)])
      assert {:ok, hop3} = Monotonic.delegate(hop2, [cap(:report)])

      assert hop3.depth == 3

      for {child, parent} <- [{hop1, root_chain}, {hop2, hop1}, {hop3, hop2}] do
        assert MapSet.subset?(MapSet.new(child.effective), MapSet.new(parent.effective))
      end

      assert hop3.effective == [cap(:report)]

      # Positive control: the root, holding both real broker grants, actuates
      # both capabilities for real.
      assert dispatch(root_principal, "report", "a-root-report").status.state == :completed

      assert dispatch(root_principal, "admin_report", "a-root-admin").status.state == :completed

      assert length(ledger_for(root_principal)) == 2

      # The hop-3 child, granted EXACTLY its narrowed set in the real broker,
      # actuates the narrowed capability for real: one real record.
      child3 = "mono-a-child3"
      grant!(child3, :report)

      assert dispatch(child3, "report", "a-child3-report").status.state == :completed
      assert length(ledger_for(child3)) == 1

      # ...and cannot actuate beyond the narrowed set through the real agent:
      # the real CommandBus fails it closed, the ledger is untouched.
      assert dispatch(child3, "admin_report", "a-child3-escalation").status.state == :failed
      assert length(ledger_for(child3)) == 1
    end
  end

  describe "(b) attempted escalation at hop 2" do
    test "typed refusal receipt, gate-level refusal, zero downstream side effects" do
      root_principal = "mono-b-root"
      grant!(root_principal, :report)
      grant!(root_principal, :admin_report)

      root_chain = Monotonic.root([cap(:report), cap(:admin_report)])
      assert {:ok, hop1} = Monotonic.delegate(root_chain, [cap(:report)])

      # The escalation attempt: hop 2 asks for a capability hop 1 never held.
      assert {:error, refusal} =
               Monotonic.delegate(hop1, [cap(:report), cap(:admin_report)])

      assert refusal.code == :refused_non_monotonic_grant
      assert refusal.excess == [cap(:admin_report)]
      assert refusal.parent_effective == [cap(:report)]
      assert refusal.requested == Enum.sort([cap(:report), cap(:admin_report)])
      assert refusal.depth == 2
      assert String.starts_with?(refusal.digest, "sha256:")
      assert %DateTime{} = refusal.refused_at

      # The receipt is content-addressed: the same non-monotonic attempt
      # yields the same canonical digest (replayable), a different attempt
      # does not.
      assert {:error, same} = Monotonic.delegate(hop1, [cap(:report), cap(:admin_report)])
      assert same.digest == refusal.digest

      assert {:error, different} = Monotonic.delegate(root_chain, ["ops:ghost"])
      assert different.excess == ["ops:ghost"]
      assert different.digest != refusal.digest

      # The expanded capability is refused identically when it is *used*:
      # the decision gate refuses it against the narrowed chain with the
      # same typed receipt, before any dispatch.
      escalated_effect =
        PreparedEffect.new("mono-b-child", cap(:admin_report), %{"ledger" => "x"}, %{})

      assert {:error, used_refusal} =
               DecisionGate.admit_delegated(
                 policy_evidence(escalated_effect),
                 escalated_effect,
                 @pdp,
                 hop1
               )

      assert used_refusal.code == :refused_non_monotonic_grant

      # Positive controls: the narrowed capability admits through the gate
      # with the chain, and the nil-chain form degrades to plain admit/3.
      narrowed_effect =
        PreparedEffect.new("mono-b-child", cap(:report), %{"ledger" => "x"}, %{})

      assert :ok =
               DecisionGate.admit_delegated(policy_evidence(narrowed_effect), narrowed_effect, @pdp, hop1)

      assert :ok =
               DecisionGate.admit_delegated(policy_evidence(narrowed_effect), narrowed_effect, @pdp, nil)

      # Zero downstream side effects, proven on the real path: the child
      # principal holds exactly its lawful narrowed set in the real broker.
      # The escalated dispatch fails closed at the real CommandBus, and an
      # independent Ash.read! confirms nothing was created.
      child_principal = "mono-b-child"
      grant!(child_principal, :report)

      assert dispatch(child_principal, "admin_report", "b-escalation").status.state == :failed
      assert ledger_for(child_principal) == []

      # Positive control: the same principal's LAWFUL dispatch really works
      # and really creates exactly one record -- the zero above is the
      # escalation refusal, not a broken fixture.
      assert dispatch(child_principal, "report", "b-lawful").status.state == :completed
      assert length(ledger_for(child_principal)) == 1
    end
  end

  describe "(c) intersection semantics" do
    test "overlapping parent grants -> the child holds exactly the intersection" do
      extra_a = "ops:extra-a"
      extra_b = "ops:extra-b"

      parent_a = Monotonic.root([cap(:report), cap(:admin_report), extra_a])
      parent_b = Monotonic.root([cap(:report), cap(:admin_report), extra_b])

      # Requesting beyond the intersection clamps to exactly the
      # intersection: neither parent's exclusive extras survive, and the
      # child cannot exceed either parent.
      assert {:ok, child} =
               Monotonic.delegate([parent_a, parent_b], [
                 cap(:report),
                 cap(:admin_report),
                 "ops:union-attempt"
               ])

      assert child.effective == Enum.sort([cap(:report), cap(:admin_report)])

      for parent <- [parent_a, parent_b] do
        assert MapSet.subset?(MapSet.new(child.effective), MapSet.new(parent.effective))
      end

      # Real side: a principal granted exactly the intersection actuates the
      # shared capability for real; an out-of-intersection capability fails
      # closed with the ledger untouched.
      child_principal = "mono-c-child"
      grant!(child_principal, :report)

      assert dispatch(child_principal, "report", "c-intersection").status.state == :completed
      assert dispatch(child_principal, "admin_report", "c-beyond").status.state == :failed
      assert length(ledger_for(child_principal)) == 1
    end
  end

  describe "(d) property: narrowing is monotone" do
    @pool ["cap:alpha", "cap:beta", "cap:gamma", "cap:delta", "cap:epsilon"]

    property "narrow(parent, child) is always a subset of parent; delegate/2 agrees" do
      check all(
              parent <- list_of(member_of(@pool), min_length: 0, max_length: 6),
              requested <- list_of(member_of(@pool), min_length: 0, max_length: 6),
              max_runs: 40
            ) do
        parent_set = Monotonic.set(parent)
        requested_set = Monotonic.set(requested)

        # The total projection: always lawful, always a subset.
        effective = Monotonic.narrow(parent_set, requested_set)
        assert MapSet.subset?(MapSet.new(effective), MapSet.new(parent_set))

        # delegate/2 is narrow/2's enforcing twin: {:ok, ...} iff requested
        # ⊆ parent, else the typed refusal with the exact excess.
        case Monotonic.delegate(Monotonic.root(parent_set), requested_set) do
          {:ok, child} ->
            assert requested_set -- parent_set == []
            assert child.effective == requested_set
            assert MapSet.subset?(MapSet.new(child.effective), MapSet.new(parent_set))

          {:error, refusal} ->
            assert requested_set -- parent_set != []
            assert refusal.code == Monotonic.refusal_code()
            assert refusal.excess == requested_set -- parent_set
            assert refusal.parent_effective == parent_set
        end
      end
    end
  end
end
