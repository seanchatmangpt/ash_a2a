defmodule AshA2A.CommandBusOutboxChicagoTest do
  @moduledoc """
  Chicago-school evidence for the A2A-2601 receipt boundary.

  The suite exercises real consequence mutation, real receipt stores, real
  filesystem journal entries, bounded primary-store retries, killed-Memory
  recovery, replay, pre-DO anchor refusal, and the double-persistence-failure
  boundary where only the pre-dispatch pending receipt remains.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Command, CommandBus, Identity, Receipt, ReceiptOutbox, ReceiptStore}
  alias AshA2A.Test.Fixture.FreedomGym.Facilitator
  alias AshA2A.Test.Fixture.FreedomGym.MeetingPlan

  defmodule FlakyCommitReceiptStore do
    @behaviour AshA2A.ReceiptStore
    alias AshA2A.ReceiptStore.Memory

    def start_flag!(test_module) do
      flag_name = Module.concat(test_module, "FailFlag#{System.unique_integer([:positive])}")
      {:ok, _} = Agent.start_link(fn -> %{fail?: false, commits: 0} end, name: flag_name)
      flag_name
    end

    def fail_commits!(flag), do: Agent.update(flag, &Map.put(&1, :fail?, true))
    def heal!(flag), do: Agent.update(flag, &Map.put(&1, :fail?, false))
    def commit_count(flag), do: Agent.get(flag, & &1.commits)

    @impl true
    def claim(command, opts), do: Memory.claim(command, opts)

    @impl true
    def commit(receipt, opts) do
      fail? =
        Agent.get_and_update(opts[:fail_flag], fn state ->
          {state.fail?, %{state | commits: state.commits + 1}}
        end)

      if fail? do
        {:error, :injected_failure}
      else
        Memory.commit(receipt, opts)
      end
    end

    @impl true
    def fetch(id, opts), do: Memory.fetch(id, opts)
  end

  defmodule FinalizationSabotageStore do
    @behaviour AshA2A.ReceiptStore
    alias AshA2A.ReceiptStore.Memory

    @impl true
    def claim(command, opts), do: Memory.claim(command, opts)

    @impl true
    def commit(_receipt, _opts) do
      :ok = File.chmod(ReceiptOutbox.dir(), 0o500)
      {:error, :injected_primary_failure}
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
      File.chmod(outbox_dir, 0o700)
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

  test "consequence + primary commit failure finalizes one outboxed receipt and later reconciles",
       %{store_opts: store_opts, outbox_dir: outbox_dir} do
    plan_name = :"outbox_falsifier_#{System.unique_integer([:positive])}"
    :ok = MeetingPlan.reset(plan_name)

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

    assert {:error, %{code: :receipt_commit_pending, receipt: receipt}} =
             run_command(command, FlakyCommitReceiptStore, flaky_opts)

    assert receipt.status == :completed
    assert receipt.consequence == :change

    # One immediate commit plus one retry after each configured delay.
    assert FlakyCommitReceiptStore.commit_count(flag) == 3

    assert {:reply, [%{data: %{phase: receipt_phase}}]} = receipt.reply
    assert {:ok, next_phase} = MeetingPlan.next_phase(plan_name)
    assert next_phase != receipt_phase

    assert [%Receipt{receipt_id: journaled_id, status: :completed}] = ReceiptOutbox.entries()
    assert journaled_id == receipt.receipt_id

    assert [entry_file] = Enum.filter(File.ls!(outbox_dir), &String.ends_with?(&1, ".receipt"))
    assert byte_size(File.read!(Path.join(outbox_dir, entry_file))) > 0
    refute match?({:ok, _receipt}, ReceiptStore.Memory.fetch(command.command_id, store_opts))

    assert_receive {:outboxed_telemetry, %{receipt: %{receipt_id: receipt_id}}}, 1_000
    assert receipt_id == receipt.receipt_id

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

    assert ReceiptOutbox.count() == 0
    assert {:ok, stored} = ReceiptStore.Memory.fetch(command.command_id, store_opts)
    assert stored.receipt_id == receipt.receipt_id
    assert stored.status == :completed
  end

  test "outbox anchor failure refuses consequence before DO", %{
    store_opts: store_opts,
    outbox_dir: outbox_dir
  } do
    plan_name = :"outbox_anchor_refusal_#{System.unique_integer([:positive])}"
    probe_name = :"outbox_anchor_probe_#{System.unique_integer([:positive])}"
    :ok = MeetingPlan.reset(plan_name)
    :ok = MeetingPlan.reset(probe_name)

    blocked_parent = Path.join(outbox_dir, "not-a-directory")
    File.mkdir_p!(outbox_dir)
    File.write!(blocked_parent, "blocked")
    Application.put_env(:ash_a2a, :receipt_outbox_dir, Path.join(blocked_parent, "child"))

    command = next_phase_command(plan_name, "outbox-anchor-refusal-1")

    assert {:error, %{code: :receipt_anchor_unavailable}} =
             run_command(command, ReceiptStore.Memory, store_opts)

    # First real read of both plans must be the same phase. If dispatch had
    # crossed DO, the target plan would already be one phase ahead.
    assert {:ok, target_phase} = MeetingPlan.next_phase(plan_name)
    assert {:ok, probe_phase} = MeetingPlan.next_phase(probe_name)
    assert target_phase == probe_phase

    assert {:ok, refusal_receipt} = ReceiptStore.Memory.fetch(command.command_id, store_opts)
    assert refusal_receipt.status == :failed
  end

  test "if final outcome persistence fails after DO, pending anchor remains and blocks second DO",
       %{store_opts: store_opts, outbox_dir: outbox_dir} do
    plan_name = :"outbox_pending_anchor_#{System.unique_integer([:positive])}"
    probe_name = :"outbox_pending_probe_#{System.unique_integer([:positive])}"
    :ok = MeetingPlan.reset(plan_name)
    :ok = MeetingPlan.reset(probe_name)

    command = next_phase_command(plan_name, "outbox-pending-anchor-1")

    assert {:error,
            %{
              code: :receipt_commit_pending,
              outcome_durable?: false,
              receipt: final_receipt
            }} = run_command(command, FinalizationSabotageStore, store_opts)

    :ok = File.chmod(outbox_dir, 0o700)

    assert [%Receipt{receipt_id: anchor_id, status: :pending}] = ReceiptOutbox.entries()
    assert anchor_id == final_receipt.receipt_id

    # Original dispatch happened exactly once.
    assert {:ok, phase_after_original} = MeetingPlan.next_phase(plan_name)
    assert {:ok, probe_phase_1} = MeetingPlan.next_phase(probe_name)
    assert {:ok, probe_phase_2} = MeetingPlan.next_phase(probe_name)
    refute phase_after_original == probe_phase_1
    assert phase_after_original == probe_phase_2

    # Reconcile the pending anchor into the real store, then replay the same
    # command. Replay returns pending evidence and does not dispatch again.
    assert {:ok, %{committed: 1, remaining: 0}} =
             CommandBus.reconcile_outboxed_receipts(ReceiptStore.Memory, store_opts)

    assert {:ok, replayed} = run_command(command, ReceiptStore.Memory, store_opts)
    assert replayed.replayed? == true
    assert replayed.status == :pending
    assert replayed.receipt_id == anchor_id

    assert {:ok, phase_after_replay} = MeetingPlan.next_phase(plan_name)
    {:ok, probe_phase_3} = MeetingPlan.next_phase(probe_name)
    assert phase_after_replay == probe_phase_3
  end

  test "a store that lost its claim is repaired by the explicit reconcile path", %{} do
    plan_name = :"outbox_reclaim_#{System.unique_integer([:positive])}"
    :ok = MeetingPlan.reset(plan_name)

    name = Module.concat(__MODULE__, "CrashStore#{System.unique_integer([:positive])}")
    {:ok, _pid} = GenServer.start(AshA2A.ReceiptStore.Memory, %{}, name: name)
    store_opts = [name: name]

    command = next_phase_command(plan_name, "outbox-reclaim-1")

    assert {:error, %{code: :receipt_commit_pending, receipt: receipt}} =
             run_command(command, AshA2A.Test.CrashingReceiptStoreFixture, store_opts)

    assert receipt.status == :completed
    assert GenServer.whereis(name) == nil
    assert ReceiptOutbox.count() == 1

    {:ok, _pid} = GenServer.start(AshA2A.ReceiptStore.Memory, %{}, name: name)

    assert {:ok, %{committed: 1, remaining: 0}} =
             CommandBus.reconcile_outboxed_receipts(AshA2A.ReceiptStore.Memory, store_opts)

    assert ReceiptOutbox.count() == 0
    assert {:ok, stored} = ReceiptStore.Memory.fetch(command.command_id, store_opts)
    assert stored.receipt_id == receipt.receipt_id
    assert stored.status == :completed
  end

  test "replaying the same command after a reconciled final receipt performs no second consequence",
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

    assert {:ok, replayed} = run_command(command, FlakyCommitReceiptStore, flaky_opts)
    assert replayed.replayed? == true
    assert replayed.receipt_id == receipt.receipt_id

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
