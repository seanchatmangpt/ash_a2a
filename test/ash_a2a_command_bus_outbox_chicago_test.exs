defmodule AshA2A.CommandBusOutboxChicagoTest do
  @moduledoc """
  Chicago-school proof closing A2A-2601 (docs/jira/v26.9.15): the exact
  review falsifier -- make `claim/2` succeed, execute a real
  idempotently-observable mutation, then make `commit/2` fail -- must no
  longer be able to leave "consequence exists, committed receipt does not"
  as an unrecoverable end state.

  Everything real, nothing mocked: the FreedomGym `Facilitator` fixture's
  `:next_phase` skill performs a REAL plan-position mutation on a REAL
  `Agent` (`AshA2A.Test.Fixture.FreedomGym.MeetingPlan`); the failing
  stores are REAL `AshA2A.ReceiptStore` implementations (one injects real
  `{:error, :injected_failure}` commit replies behind an Agent-held flag,
  one -- `AshA2A.Test.CrashingReceiptStoreFixture` -- genuinely stops the
  backing Memory GenServer mid-commit for a real `:noproc` exit); the
  outbox is a REAL on-disk journal in a REAL per-test tmp directory; and
  reconciliation runs the real
  `AshA2A.CommandBus.reconcile_outboxed_receipts/2` path, including the
  re-claim branch a restarted Memory store needs.
  """

  use ExUnit.Case, async: false

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Command, CommandBus, Identity, ReceiptStore}
  alias AshA2A.Test.Fixture.FreedomGym.Facilitator
  alias AshA2A.Test.Fixture.FreedomGym.MeetingPlan

  # A REAL ReceiptStore implementation, not a mock: `claim/2`/`fetch/2`
  # delegate to the real `AshA2A.ReceiptStore.Memory` under `opts[:name]`;
  # `commit/2` returns a real `{:error, :injected_failure}` reply while the
  # operator flag (a real Agent) is set, and delegates to the real Memory
  # commit once healed. It never asserts on how it was called; the failure
  # it produces is a genuine store-level reply a caller must handle.
  defmodule FlakyCommitReceiptStore do
    @behaviour AshA2A.ReceiptStore
    alias AshA2A.ReceiptStore.Memory

    def start_flag!(test_module) do
      flag_name = Module.concat(test_module, "FailFlag#{System.unique_integer([:positive])}")
      {:ok, _} = Agent.start_link(fn -> false end, name: flag_name)
      flag_name
    end

    def fail_commits!(flag), do: Agent.update(flag, fn _ -> true end)
    def heal!(flag), do: Agent.update(flag, fn _ -> false end)

    @impl true
    def claim(command, opts), do: Memory.claim(command, opts)

    @impl true
    def commit(receipt, opts) do
      if Agent.get(opts[:fail_flag], & &1) do
        {:error, :injected_failure}
      else
        Memory.commit(receipt, opts)
      end
    end

    @impl true
    def fetch(id, opts), do: Memory.fetch(id, opts)
  end

  setup do
    outbox_dir =
      Path.join(System.tmp_dir!(), "ash-a2a-outbox-chicago-#{System.unique_integer([:positive])}")

    Application.put_env(:ash_a2a, :receipt_outbox_dir, outbox_dir)
    Application.put_env(:ash_a2a, :receipt_commit_retry_delays_ms, [5, 5])

    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: name})

    on_exit(fn ->
      Application.delete_env(:ash_a2a, :receipt_commit_retry_delays_ms)
      Application.delete_env(:ash_a2a, :receipt_outbox_dir)
      File.rm_rf!(outbox_dir)
    end)

    {:ok, store_opts: [name: name], outbox_dir: outbox_dir}
  end

  defp next_phase_command(plan_name, command_id) do
    capability_id = "AshA2A.Test.Fixture.FreedomGym.Facilitator.next_phase"
    principal = Identity.principal("subject-outbox-1")
    authority = Authority.new(principal, capability_id, token_id: "auth-outbox-#{command_id}")

    Command.new(capability_id,
      command_id: command_id,
      agent_id: "agent-1",
      principal_id: principal,
      authority: authority,
      input: %{plan_name: plan_name, prompt_text: "advance the real plan"}
    )
  end

  defp run_command(command, store, store_opts) do
    CommandBus.run(command, data_message(command.input), Facilitator,
      store: store,
      store_opts: store_opts
    )
  end

  test "the review falsifier: consequence observed + commit failing never ends unreceipted; a later command opportunistically reconciles",
       %{store_opts: store_opts, outbox_dir: outbox_dir} do
    plan_name = :"outbox_falsifier_#{System.unique_integer([:positive])}"
    :ok = MeetingPlan.reset(plan_name)

    # Observe the `[:ash_a2a, :receipt, :outboxed]` event the state machine
    # emits for a consequence whose receipt commit is pending.
    parent = self()
    handler_ref = make_ref()

    :ok =
      :telemetry.attach(
        {__MODULE__, handler_ref},
        [:ash_a2a, :receipt, :outboxed],
        fn _event, _measurements, meta, _config -> send(parent, {:outboxed_telemetry, meta}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach({__MODULE__, handler_ref}) end)

    flag = FlakyCommitReceiptStore.start_flag!(__MODULE__)
    flaky_opts = Keyword.put(store_opts, :fail_flag, flag)
    FlakyCommitReceiptStore.fail_commits!(flag)

    command = next_phase_command(plan_name, "outbox-falsifier-1")

    # 1. Claim succeeded, the REAL dispatch executed the REAL plan mutation,
    #    and every commit attempt failed: the typed pending outcome, with the
    #    receipt itself carried in the error (previously discarded).
    assert {:error, %{code: :receipt_commit_pending, receipt: receipt}} =
             run_command(command, FlakyCommitReceiptStore, flaky_opts)

    assert receipt.status == :completed
    assert receipt.consequence == :change

    # 2. The consequence is idempotently observable against the real plan:
    #    the command's reply carried the plan's phase #1, so the plan's own
    #    NEXT read is phase #2 -- if the dispatch had not actuated, this
    #    direct observation would still return phase #1.
    assert {:reply, [%{data: %{phase: receipt_phase}}]} = receipt.reply
    assert {:ok, next_phase} = MeetingPlan.next_phase(plan_name)
    assert next_phase != receipt_phase

    # 3. The outcome is durably journaled on real disk, exactly once, and
    #    the store itself has no receipt for the command yet.
    assert [%{receipt_id: journaled_id}] = AshA2A.ReceiptOutbox.entries()
    assert journaled_id == receipt.receipt_id

    assert [entry_file] = Enum.filter(File.ls!(outbox_dir), &String.ends_with?(&1, ".receipt"))
    assert byte_size(File.read!(Path.join(outbox_dir, entry_file))) > 0
    refute match?({:ok, _receipt}, ReceiptStore.Memory.fetch(command.command_id, store_opts))

    # 4. The outboxed telemetry event fired with the receipt, so
    #    observational consumers keep their evidence for the consequence.
    assert_receive {:outboxed_telemetry, %{receipt: %{receipt_id: receipt_id}}}, 1_000
    assert receipt_id == receipt.receipt_id

    # 5. Recovery: heal the store, then push an UNRELATED observe command
    #    through the same bus -- its opportunistic pre-claim reconcile must
    #    repair the previous command's pending receipt.
    FlakyCommitReceiptStore.heal!(flag)

    echo_command =
      Command.new("AshA2A.Test.Fixture.FreedomGym.Facilitator.run_phase",
        command_id: "outbox-falsifier-followup-1",
        agent_id: "agent-1",
        principal_id: "anonymous",
        input: %{phase: :unrelated_followup, prompt_text: "unrelated observe command"}
      )

    assert {:ok, _observe_receipt} =
             run_command(echo_command, FlakyCommitReceiptStore, flaky_opts)

    assert AshA2A.ReceiptOutbox.count() == 0
    assert {:ok, stored} = ReceiptStore.Memory.fetch(command.command_id, store_opts)
    assert stored.receipt_id == receipt.receipt_id
    assert stored.status == :completed
  end

  test "a store that LOST its claim (killed Memory) is repaired by the explicit reconcile path",
       %{} do
    plan_name = :"outbox_reclaim_#{System.unique_integer([:positive])}"
    :ok = MeetingPlan.reset(plan_name)

    # Deliberately UNSUPERVISED so the crashing store's real kill is not
    # transparently healed by ExUnit's supervisor (same discipline as
    # `AshA2A.CommandBusTest`'s crash tests) -- the setup block's supervised
    # store would silently re-register the name within milliseconds.
    name = Module.concat(__MODULE__, "CrashStore#{System.unique_integer([:positive])}")
    {:ok, _pid} = GenServer.start(AshA2A.ReceiptStore.Memory, %{}, name: name)
    store_opts = [name: name]

    command = next_phase_command(plan_name, "outbox-reclaim-1")

    assert {:error, %{code: :receipt_commit_pending, receipt: receipt}} =
             run_command(command, AshA2A.Test.CrashingReceiptStoreFixture, store_opts)

    assert receipt.status == :completed
    assert GenServer.whereis(name) == nil
    assert AshA2A.ReceiptOutbox.count() == 1

    # Operator restarts the store: a fresh Memory has no memory of the
    # original claim, so reconciliation must take the re-claim branch
    # (claim the same command id/fingerprint, then commit the journaled
    # receipt) rather than failing with :unclaimed_command forever.
    {:ok, _pid} = GenServer.start(AshA2A.ReceiptStore.Memory, %{}, name: name)

    assert {:ok, %{committed: 1, remaining: 0}} =
             CommandBus.reconcile_outboxed_receipts(AshA2A.ReceiptStore.Memory, store_opts)

    assert AshA2A.ReceiptOutbox.count() == 0
    assert {:ok, stored} = ReceiptStore.Memory.fetch(command.command_id, store_opts)
    assert stored.receipt_id == receipt.receipt_id
    assert stored.status == :completed
  end

  test "replaying the same command after a reconciled outbox returns the stored receipt, not a second consequence",
       %{store_opts: store_opts} do
    plan_name = :"outbox_replay_#{System.unique_integer([:positive])}"
    :ok = MeetingPlan.reset(plan_name)

    flag = FlakyCommitReceiptStore.start_flag!(__MODULE__)
    flaky_opts = Keyword.put(store_opts, :fail_flag, flag)
    FlakyCommitReceiptStore.fail_commits!(flag)

    command = next_phase_command(plan_name, "outbox-replay-1")

    assert {:error, %{code: :receipt_commit_pending, receipt: receipt}} =
             run_command(command, FlakyCommitReceiptStore, flaky_opts)

    FlakyCommitReceiptStore.heal!(flag)

    assert {:ok, %{committed: 1, remaining: 0}} =
             CommandBus.reconcile_outboxed_receipts(FlakyCommitReceiptStore, flaky_opts)

    # Same command, same fingerprint, healthy store: replay serves the
    # reconciled receipt WITHOUT dispatching a second real plan mutation.
    assert {:ok, replayed} = run_command(command, FlakyCommitReceiptStore, flaky_opts)
    assert replayed.replayed? == true
    assert replayed.receipt_id == receipt.receipt_id

    # Exactly ONE plan advance happened: the original command's receipt
    # holds phase #1, so the plan's next read must be phase #2 -- measured
    # against a fresh probe plan (every plan name gets the SAME real HDDL
    # phase sequence), not just "different from phase #1": if the replay
    # had mutated the plan again, this read would return phase #3.
    probe = :"outbox_replay_probe_#{System.unique_integer([:positive])}"
    {:ok, phase_1} = MeetingPlan.next_phase(probe)
    {:ok, phase_2} = MeetingPlan.next_phase(probe)
    {:ok, phase_3} = MeetingPlan.next_phase(probe)

    assert {:reply, [%{data: %{phase: receipt_phase}}]} = receipt.reply
    assert receipt_phase == phase_1
    assert {:ok, next_read} = MeetingPlan.next_phase(plan_name)
    assert next_read == phase_2
    refute next_read == phase_3
  end
end
