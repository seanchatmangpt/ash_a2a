defmodule AshA2A.Hilt.WorkOrderExecutionIdentityTest do
  use ExUnit.Case, async: true

  alias AshA2A.{
    Authority,
    Command,
    ExecutionIdentity,
    ExecutionSnapshot,
    Identity,
    SemanticSubject
  }

  alias AshA2A.Hilt.WorkOrder

  @digest "sha256:" <> String.duplicate("a", 64)
  @digest_b "sha256:" <> String.duplicate("b", 64)
  @digest_c "sha256:" <> String.duplicate("c", 64)

  defp subject do
    {:ok, subject} =
      SemanticSubject.new(
        graph_digest: @digest,
        projection_digest: @digest_b,
        manufacturer_digest: @digest_c,
        ephemeral?: false
      )

    subject
  end

  defp command(opts \\ []) do
    capability = Keyword.get(opts, :capability, "Acme.Inventory.reserve")
    principal = Identity.principal("principal-1")

    authority =
      if Keyword.get(opts, :authority?, false) do
        Authority.new(principal, capability,
          token_id: "grant-1",
          source: :authority_broker,
          issued_at: ~U[2026-09-25 12:00:00Z],
          constraints: %{region: "us-west"}
        )
      end

    Command.new(capability,
      command_id: Keyword.get(opts, :command_id, "command-1"),
      agent_id: "agent-1",
      principal_id: principal,
      task_id: "task-1",
      input: %{sku: "sku-1", quantity: 1},
      authority: authority,
      semantic_subject: subject(),
      submitted_at: ~U[2026-09-25 12:00:00Z],
      metadata: %{
        candidate_digest: Keyword.get(opts, :candidate_digest, "sha256:candidate"),
        provider: Keyword.get(opts, :provider, "provider-a"),
        transport: Keyword.get(opts, :transport, "wss")
      }
    )
  end

  defp work_order(command, consequence \\ :observe, ceiling \\ :observe) do
    WorkOrder.for_command!(command, consequence,
      work_order_id: "wo-1",
      observation_bounds: %{read: ["inventory"], max_items: 10},
      action_bounds: %{actions: [command.capability_id], max_external_requests: 1},
      authority_ceiling: ceiling,
      process_evidence: %{ocel_type: "sa2a_work_order", required: true},
      falsifier: %{refuse_on: [:stale_subject, :authority_laundering]}
    )
  end

  test "work order binds exact command candidate subject capability and bounds" do
    candidate = command()
    work_order = work_order(candidate)
    bound = WorkOrder.bind_command(work_order, candidate)

    assert :ok = WorkOrder.admit_command(work_order, bound)
    assert Command.work_order_digest(bound) == WorkOrder.identity_digest(work_order)
    assert Command.candidate_digest(bound) == work_order.candidate_digest
    assert String.starts_with?(WorkOrder.identity_digest(work_order), "sha256:")
  end

  test "provider and transport substitution do not alter work-order identity" do
    left = command(provider: "provider-a", transport: "wss")
    right = command(provider: "provider-b", transport: "http")

    left_order = work_order(left)
    right_order = work_order(right)

    assert WorkOrder.identity_digest(left_order) == WorkOrder.identity_digest(right_order)

    left_bound = WorkOrder.bind_command(left_order, left)
    right_bound = WorkOrder.bind_command(right_order, right)

    assert left_bound.fingerprint == right_bound.fingerprint
  end

  test "candidate substitution is refused even when every topology field is unchanged" do
    candidate = command()
    work_order = work_order(candidate)
    bound = WorkOrder.bind_command(work_order, candidate)

    substituted =
      Command.new(bound.capability_id,
        command_id: bound.command_id,
        agent_id: bound.agent_id,
        principal_id: bound.principal_id,
        task_id: bound.task_id,
        input: bound.input,
        authority: bound.authority,
        semantic_subject: bound.semantic_subject,
        submitted_at: bound.submitted_at,
        metadata: Map.put(bound.metadata, :candidate_digest, "sha256:forged-candidate")
      )

    assert {:error, :stale_candidate_identity} =
             WorkOrder.admit_command(work_order, substituted)
  end

  test "DO consequence cannot be laundered through a lower authority ceiling" do
    candidate = command(authority?: true)
    low_ceiling = work_order(candidate, :external_do, :construct)
    bound = WorkOrder.bind_command(low_ceiling, candidate)

    assert {:error, :authority_ceiling_exceeded} =
             WorkOrder.admit_command(low_ceiling, bound)
  end

  test "DO consequence requires an exact admitted authority grant" do
    candidate = command(authority?: true)
    order = work_order(candidate, :external_do, :do)
    bound = WorkOrder.bind_command(order, candidate)

    assert :ok = WorkOrder.admit_command(order, bound)

    no_authority =
      Command.new(bound.capability_id,
        command_id: bound.command_id,
        agent_id: bound.agent_id,
        principal_id: bound.principal_id,
        task_id: bound.task_id,
        input: bound.input,
        semantic_subject: bound.semantic_subject,
        submitted_at: bound.submitted_at,
        metadata: bound.metadata
      )

    assert {:error, :authority_required} = WorkOrder.admit_command(order, no_authority)
  end

  test "execution identity manufactures snapshot identity and detects drift" do
    candidate = command()
    order = work_order(candidate)
    bound = WorkOrder.bind_command(order, candidate)
    identity = ExecutionIdentity.from_work_order!(order, bound)

    snapshot =
      ExecutionIdentity.snapshot!(identity, "sha256:manifest",
        provider_projection: %{provider: "provider-a", transport: "wss"},
        worker_id: "worker-a"
      )

    assert :ok = ExecutionIdentity.verify_snapshot(identity, snapshot)

    provider_changed =
      %{
        snapshot
        | provider_projection: %{provider: "provider-b", transport: "http"},
          worker_id: "worker-b"
      }

    assert :ok = ExecutionIdentity.verify_snapshot(identity, provider_changed)

    assert ExecutionSnapshot.semantic_identity_digest(snapshot) ==
             ExecutionSnapshot.semantic_identity_digest(provider_changed)

    stale = %{snapshot | candidate_digest: "sha256:other-candidate"}

    assert {:error, {:identity_drift, [:candidate_digest]}} =
             ExecutionIdentity.verify_snapshot(identity, stale)
  end

  test "snapshot manufacture refuses caller attempts to overwrite derived identity" do
    candidate = command()
    order = work_order(candidate)
    bound = WorkOrder.bind_command(order, candidate)
    identity = ExecutionIdentity.from_work_order!(order, bound)

    assert_raise ArgumentError, ~r/identity fields are derived/, fn ->
      ExecutionIdentity.snapshot!(identity, "sha256:manifest",
        candidate_digest: "sha256:forged-candidate"
      )
    end
  end

  test "authority evidence/transport is excluded while grant semantics remain identity-bearing" do
    base = command(authority?: true)
    order = work_order(base, :external_do, :do)
    bound = WorkOrder.bind_command(order, base)
    identity = ExecutionIdentity.from_work_order!(order, bound)

    same_grant_different_evidence =
      %{
        bound.authority
        | evidence: %{transport_identity: "different-provider-session"}
      }

    rebound = %{bound | authority: same_grant_different_evidence}
    same = ExecutionIdentity.from_work_order!(order, rebound)

    assert same.authority_digest == identity.authority_digest
  end
end
