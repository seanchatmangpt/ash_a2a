defmodule AshA2A.CommandBusTest do
  use ExUnit.Case

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Command, CommandBus, Identity, ReceiptStore, SemanticSubject}
  alias AshA2A.Hilt.WorkOrder
  alias AshA2A.Test.Fixture.{Crashy, Echo, Item}

  setup do
    # A2A-2601: commit retries default to [50, 150] ms -- real production
    # transient-window recovery, but slow for this suite's 100ms
    # assert_receive windows. Shrink them here; the outbox Chicago suite
    # exercises the production-shaped delays explicitly.
    Application.put_env(:ash_a2a, :receipt_commit_retry_delays_ms, [1, 1])
    on_exit(fn -> Application.delete_env(:ash_a2a, :receipt_commit_retry_delays_ms) end)

    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: name})
    %{store_opts: [name: name]}
  end

  test "read command produces a receipt and same command replays without a second claim", %{
    store_opts: store_opts
  } do
    command =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "read-1",
        agent_id: "agent-1",
        principal_id: "anonymous",
        input: %{}
      )

    message = data_message(%{})

    assert {:ok, first} = CommandBus.run(command, message, Echo, store_opts: store_opts)
    refute first.replayed?
    assert first.status == :completed
    assert first.consequence == :observe

    assert {:ok, replay} = CommandBus.run(command, message, Echo, store_opts: store_opts)
    assert replay.replayed?
    assert replay.receipt_id == first.receipt_id
  end

  test "same command id with changed semantic input is rejected by the claim store", %{
    store_opts: store_opts
  } do
    one =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "conflict-1",
        agent_id: "agent-1",
        principal_id: "anonymous",
        input: %{}
      )

    two =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "conflict-1",
        agent_id: "agent-1",
        principal_id: "anonymous",
        input: %{other: true}
      )

    message = data_message(%{})

    assert {:ok, _} = CommandBus.run(one, message, Echo, store_opts: store_opts)

    assert {:error, %{code: :command_conflict}} =
             CommandBus.run(two, message, Echo, store_opts: store_opts)
  end

  test "non-read capability requires matching authority before dispatcher entry", %{
    store_opts: store_opts
  } do
    command =
      Command.new("AshA2A.Test.Fixture.Item.create",
        command_id: "create-1",
        agent_id: "agent-1",
        principal_id: "subject-1",
        input: %{label: "widget"}
      )

    assert {:error, %{code: :authority_required}} =
             CommandBus.run(command, data_message(%{"label" => "widget"}), Item,
               store_opts: store_opts
             )

    assert :error = ReceiptStore.Memory.fetch(command.command_id, store_opts)
  end

  test "matching authority admits a real create and commits its receipt", %{
    store_opts: store_opts
  } do
    principal = Identity.principal("subject-1")
    capability = "AshA2A.Test.Fixture.Item.create"
    authority = Authority.new(principal, capability, token_id: "auth-create-1")

    command =
      Command.new(capability,
        command_id: "create-2",
        agent_id: "agent-1",
        principal_id: principal,
        authority: authority,
        input: %{label: "widget"}
      )

    assert {:ok, receipt} =
             CommandBus.run(command, data_message(%{"label" => "widget"}), Item,
               store_opts: store_opts
             )

    assert receipt.status == :completed
    assert receipt.consequence == :change
    assert {:ok, stored} = ReceiptStore.Memory.fetch(command.command_id, store_opts)
    assert stored.receipt_id == receipt.receipt_id
  end

  test "claiming against a receipt store whose backing process is already down fails closed instead of crashing the caller" do
    # A deliberately UNSUPERVISED store instance (plain `GenServer.start/3`,
    # not `start_supervised!`) -- `AshA2A.ReceiptStore.Memory`'s `use
    # GenServer` gives it a `restart: :permanent` child_spec by default, so
    # a store started under the shared `setup` block's real ExUnit
    # supervisor would be transparently restarted under the same registered
    # name within milliseconds of being killed, masking the exact
    # transient-unavailability window this test exists to exercise.
    name = Module.concat(__MODULE__, "CrashClaimStore#{System.unique_integer([:positive])}")
    {:ok, pid} = GenServer.start(AshA2A.ReceiptStore.Memory, %{}, name: name)
    store_opts = [name: name]

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert GenServer.whereis(name) == nil

    command =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "crash-claim-1",
        agent_id: "agent-1",
        principal_id: "anonymous",
        input: %{}
      )

    message = data_message(%{})
    test_pid = self()

    {caller_pid, caller_ref} =
      spawn_monitor(fn ->
        send(test_pid, {:result, CommandBus.run(command, message, Echo, store_opts: store_opts)})
      end)

    assert_receive {:result, result}
    assert_receive {:DOWN, ^caller_ref, :process, ^caller_pid, :normal}
    assert {:error, %{code: :receipt_store_unavailable}} = result
  end

  test "receipt store crashing between claim and commit fails closed instead of crashing the caller" do
    # Same reasoning as the claim-path test above: an UNSUPERVISED store so
    # the real kill this test performs (inside
    # `AshA2A.Test.CrashingReceiptStoreFixture.commit/2`) is not
    # transparently healed by ExUnit's real supervisor before the final
    # "really is gone" assertion below runs.
    name = Module.concat(__MODULE__, "CrashCommitStore#{System.unique_integer([:positive])}")
    {:ok, _pid} = GenServer.start(AshA2A.ReceiptStore.Memory, %{}, name: name)
    store_opts = [name: name]

    command =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "crash-commit-1",
        agent_id: "agent-1",
        principal_id: "anonymous",
        input: %{}
      )

    message = data_message(%{})
    test_pid = self()

    {caller_pid, caller_ref} =
      spawn_monitor(fn ->
        result =
          CommandBus.run(command, message, Echo,
            store: AshA2A.Test.CrashingReceiptStoreFixture,
            store_opts: store_opts
          )

        send(test_pid, {:result, result})
      end)

    assert_receive {:result, result}
    assert_receive {:DOWN, ^caller_ref, :process, ^caller_pid, :normal}

    # A2A-2601: the consequence HAS happened by the time the store dies
    # between claim and commit, so the old bare
    # `:receipt_store_unavailable` outcome (which discarded the observed
    # reply) is now a typed `:receipt_commit_pending` error that CARRIES
    # the receipt, with the receipt durably journaled in the
    # `AshA2A.ReceiptOutbox` pending reconciliation.
    assert {:error, %{code: :receipt_commit_pending, receipt: %AshA2A.Receipt{} = receipt}} =
             result

    assert receipt.status == :completed
    assert [%AshA2A.Receipt{receipt_id: receipt_id}] = AshA2A.ReceiptOutbox.entries()
    assert receipt_id == receipt.receipt_id
    assert GenServer.whereis(Keyword.fetch!(store_opts, :name)) == nil
  end

  test "an exception raised inside the real dispatch path is caught, receipted as :failed, and closes the claim instead of crashing the caller",
       %{store_opts: store_opts} do
    command =
      Command.new("AshA2A.Test.Fixture.Crashy.detonate",
        command_id: "dispatch-crash-1",
        agent_id: "agent-1",
        principal_id: "anonymous",
        input: %{}
      )

    message = data_message(%{})
    test_pid = self()

    {caller_pid, caller_ref} =
      spawn_monitor(fn ->
        send(
          test_pid,
          {:result, CommandBus.run(command, message, Crashy, store_opts: store_opts)}
        )
      end)

    assert_receive {:result, result}
    assert_receive {:DOWN, ^caller_ref, :process, ^caller_pid, :normal}

    # The caller got back an ordinary, receipted `:failed` outcome -- not a
    # propagated exception and not the outer `{:error, refusal}` shape
    # `claim_receipt/3`/`commit_receipt/3` fail-closed errors use.
    assert {:ok, receipt} = result
    assert receipt.status == :failed
    assert receipt.consequence == :observe
    assert {:error, %{code: :dispatch_crashed, detail: detail}} = receipt.reply
    assert detail =~ "AshA2A.Test.Fixture.Crashy: real dispatch crash fixture"

    # The claim `claim_receipt/3` wrote before dispatch is closed by the
    # commit above -- fetchable now, not stuck at `receipt: nil`.
    assert {:ok, fetched} = ReceiptStore.Memory.fetch(command.command_id, store_opts)
    assert fetched.receipt_id == receipt.receipt_id

    # A retry with the same command (same fingerprint) replays the closed
    # receipt instead of hitting the permanent `{:error, :in_flight}` a
    # still-open (`receipt: nil`) claim would produce.
    assert {:ok, replay} = CommandBus.run(command, message, Crashy, store_opts: store_opts)
    assert replay.replayed?
    assert replay.receipt_id == receipt.receipt_id
  end

  test "HILT work order is verified before claim and survives provider substitution", %{
    store_opts: store_opts
  } do
    {:ok, subject} =
      SemanticSubject.new(
        graph_digest: "sha256:" <> String.duplicate("a", 64),
        projection_digest: "sha256:" <> String.duplicate("b", 64),
        manufacturer_digest: "sha256:" <> String.duplicate("c", 64),
        ephemeral?: false
      )

    candidate =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "hilt-read-1",
        agent_id: "agent-1",
        principal_id: "anonymous",
        task_id: "hilt-task-1",
        semantic_subject: subject,
        input: %{},
        metadata: %{
          candidate_digest: "sha256:hilt-candidate",
          provider: "provider-a",
          transport: "wss"
        }
      )

    work_order =
      WorkOrder.for_command!(candidate, :observe,
        work_order_id: "hilt-wo-1",
        observation_bounds: %{resources: ["echo"], max_items: 1},
        action_bounds: %{actions: [candidate.capability_id], max_external_requests: 0},
        authority_ceiling: :observe,
        process_evidence: %{ocel_required: true},
        falsifier: %{refuse_on: [:stale_subject, :candidate_substitution]}
      )

    bound = WorkOrder.bind_command(work_order, candidate)

    assert {:ok, first} =
             CommandBus.run(bound, data_message(%{}), Echo,
               store_opts: store_opts,
               work_order: work_order
             )

    assert first.status == :completed
    assert first.metadata.work_order_digest == WorkOrder.identity_digest(work_order)
    assert first.metadata.candidate_digest == "sha256:hilt-candidate"

    provider_changed_candidate =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "hilt-read-1",
        agent_id: "agent-1",
        principal_id: "anonymous",
        task_id: "hilt-task-1",
        semantic_subject: subject,
        input: %{},
        metadata: %{
          candidate_digest: "sha256:hilt-candidate",
          provider: "provider-b",
          transport: "http"
        }
      )

    provider_changed = WorkOrder.bind_command(work_order, provider_changed_candidate)

    assert provider_changed.fingerprint == bound.fingerprint

    assert {:ok, replay} =
             CommandBus.run(provider_changed, data_message(%{}), Echo,
               store_opts: store_opts,
               work_order: work_order
             )

    assert replay.replayed?
    assert replay.receipt_id == first.receipt_id
  end

  test "HILT stale candidate is refused before receipt-store claim", %{store_opts: store_opts} do
    {:ok, subject} =
      SemanticSubject.new(
        graph_digest: "sha256:" <> String.duplicate("d", 64),
        projection_digest: "sha256:" <> String.duplicate("e", 64),
        manufacturer_digest: "sha256:" <> String.duplicate("f", 64)
      )

    candidate =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "hilt-stale-1",
        agent_id: "agent-1",
        principal_id: "anonymous",
        task_id: "hilt-task-stale",
        semantic_subject: subject,
        input: %{},
        metadata: %{candidate_digest: "sha256:admitted-candidate"}
      )

    work_order =
      WorkOrder.for_command!(candidate, :observe,
        work_order_id: "hilt-wo-stale",
        observation_bounds: %{resources: ["echo"]},
        action_bounds: %{actions: [candidate.capability_id]},
        authority_ceiling: :observe,
        process_evidence: %{ocel_required: true},
        falsifier: %{candidate_substitution: :refuse}
      )

    bound = WorkOrder.bind_command(work_order, candidate)

    forged =
      Command.new(bound.capability_id,
        command_id: bound.command_id,
        agent_id: bound.agent_id,
        principal_id: bound.principal_id,
        task_id: bound.task_id,
        semantic_subject: bound.semantic_subject,
        input: bound.input,
        submitted_at: bound.submitted_at,
        metadata: Map.put(bound.metadata, :candidate_digest, "sha256:forged-candidate")
      )

    assert {:error, %{code: :stale_candidate_identity}} =
             CommandBus.run(forged, data_message(%{}), Echo,
               store_opts: store_opts,
               work_order: work_order
             )

    assert :error = ReceiptStore.Memory.fetch(forged.command_id, store_opts)
  end
end
