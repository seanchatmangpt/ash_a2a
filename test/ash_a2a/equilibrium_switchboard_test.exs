defmodule AshA2A.Equilibrium.SwitchboardTest do
  use ExUnit.Case, async: true
  alias AshA2A.Equilibrium.Switchboard, as: S
  alias S.{WorkOrder, Planner, Provider, Queue}

  defp w(extra \\ %{}), do: struct!(WorkOrder, Map.merge(%{id: "w", subject: "s", capability: :plan, role: :planner, policy: :bounded, authority: 0, epoch: 7, max_steps: 8}, extra))
  defp p(extra \\ %{}), do: struct!(Planner, Map.merge(%{id: :hddl, kind: :hddl, capabilities: [:plan], roles: [:planner], policies: [:bounded], authority_ceiling: 0, max_steps: 16, provider_ids: [:p1], priority: 1}, extra))
  defp v(extra \\ %{}), do: struct!(Provider, Map.merge(%{id: :p1, epoch: 7, capabilities: [:plan], alive: true}, extra))
  defp ctx, do: %{subject: "s", epoch: 7, capabilities: [:plan], roles: [:planner], policies: [:bounded], authority_ceiling: 0}

  test "admission refuses identity, epoch and authority drift" do
    assert :ok = S.admit(w(), ctx())
    assert {:error, :subject_mismatch} = S.admit(w(%{subject: "x"}), ctx())
    assert {:error, :stale_epoch} = S.admit(w(%{epoch: 6}), ctx())
    assert {:error, :authority_increase} = S.admit(w(%{authority: 1}), ctx())
    assert {:error, :unbounded_plan} = S.admit(w(%{max_steps: 0}), ctx())
  end

  test "selection is deterministic, bounded and consequence-free" do
    assert {:ok, a} = S.select(w(), [p()], [v()])
    assert {:ok, b} = S.select(w(), [p()], [v()])
    assert a == b
    assert a.consequence == :none
    assert a.standing == :candidate
    assert {:error, :no_planner} = S.select(w(%{max_steps: 17}), [p()], [v()])
    assert {:error, :no_provider} = S.select(w(), [p()], [v(%{alive: false})])
  end

  test "queue refuses duplicates and stale completion then reclaims" do
    assert {:ok, q} = S.enqueue(%Queue{limit: 1}, w())
    assert {:error, :duplicate} = S.enqueue(q, w())
    assert {:ok, _, lease, q} = S.lease(q, :worker, 7, 1)
    assert {:error, :stale_lease} = S.complete(q, "w", "bad", 7)
    q = S.reclaim(q, 8)
    assert {:ok, _, lease2, q} = S.lease(q, :worker2, 8, 1)
    refute lease.token == lease2.token
    assert {:ok, _} = S.complete(q, "w", lease2.token, 8)
  end

  test "ontology participates in executable admission contract" do
    ttl = File.read!("priv/ontology/chatman_equilibrium_switchboard.ttl")
    assert :ok = S.validate_ontology(ttl)
    assert {:error, :ontology_contract_missing, missing} = S.validate_ontology("Planner Policy")
    assert :Standing in missing
  end
end
