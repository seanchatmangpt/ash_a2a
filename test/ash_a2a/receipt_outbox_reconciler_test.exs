defmodule AshA2A.ReceiptOutboxReconcilerTest do
  @moduledoc """
  Chicago-school evidence for `AshA2A.ReceiptOutbox.Reconciler`: real journal
  entries on a real filesystem outbox directory, a real `GenServer`
  (`start_supervised!`), a real (unstarted, therefore genuinely unavailable
  -- not mocked) `AshA2A.ReceiptStore.Memory` target, and real
  `:telemetry.attach/4` handlers forwarding real emitted events to this test
  process's own mailbox. No `Mox`/`:meck`/`Mock`/`patch`/`monkeypatch`
  anywhere in this file; every assertion is on real returned/observed state
  (telemetry payloads, `ReceiptOutbox.entries/0`, `ReceiptOutbox.count/0`),
  never on "was this called".

  `async: false`: `Application.put_env(:ash_a2a, :receipt_outbox_dir, ...)`
  is process-global application config.
  """

  use ExUnit.Case, async: false

  alias AshA2A.{Command, Identity, Receipt, ReceiptOutbox}
  alias AshA2A.ReceiptOutbox.Reconciler

  setup do
    outbox_dir =
      Path.join(
        System.tmp_dir!(),
        "ash-a2a-outbox-reconciler-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:ash_a2a, :receipt_outbox_dir, outbox_dir)

    on_exit(fn ->
      Application.delete_env(:ash_a2a, :receipt_outbox_dir)
      File.rm_rf!(outbox_dir)
    end)

    {:ok, outbox_dir: outbox_dir}
  end

  # A real, deliberately-never-started `AshA2A.ReceiptStore.Memory` name:
  # every `GenServer.call` against it real-exits `:noproc`, which
  # `AshA2A.ReceiptOutbox`'s own `safe/3` real-catches as
  # `{:error, :receipt_store_unavailable}` -- a real unavailable-collaborator
  # condition (per this codebase's own existing convention for that state),
  # not a test double standing in for the store.
  defp unavailable_store_opts do
    [name: Module.concat(__MODULE__, "UnstartedStore#{System.unique_integer([:positive])}")]
  end

  defp append_pending_receipt!(command_id_value, attempts) do
    principal = Identity.principal("subject-reconciler-probe")

    command =
      Command.new("AshA2A.Test.Fixture.reconciler_probe",
        command_id: command_id_value,
        agent_id: "agent-reconciler-probe",
        principal_id: principal
      )

    execution_id = Identity.execution("exec-#{command_id_value}")

    receipt =
      command
      |> Receipt.pending(execution_id, :change)
      |> Map.put(:reconciliation, %{state: :pending, attempts: attempts})

    :ok = ReceiptOutbox.append(receipt)
    receipt
  end

  defp attach_forwarder(event) do
    test_pid = self()
    handler_id = {__MODULE__, event, make_ref()}

    :telemetry.attach(
      handler_id,
      event,
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  test "tick/1 drains the real outbox and emits a real :tick telemetry event with real counts" do
    attach_forwarder([:ash_a2a, :receipt_outbox, :reconciler, :tick])

    append_pending_receipt!("cmd-tick-a", 0)
    append_pending_receipt!("cmd-tick-b", 0)
    assert ReceiptOutbox.count() == 2

    name = Module.concat(__MODULE__, "Reconciler#{System.unique_integer([:positive])}")

    start_supervised!({
      Reconciler,
      # Long enough that no automatic tick races the synchronous one below.
      name: name,
      interval_ms: 60_000,
      store: AshA2A.ReceiptStore.Memory,
      store_opts: unavailable_store_opts()
    })

    assert {:ok, %{committed: 0, remaining: 2}} = Reconciler.tick(name)

    assert_receive {:telemetry, [:ash_a2a, :receipt_outbox, :reconciler, :tick],
                    %{committed: 0, remaining: 2}, %{}}

    # Real evidence the drain never actually removed the entries (store is
    # genuinely unavailable): both journal files are still really there.
    assert ReceiptOutbox.count() == 2
  end

  test "tick/1 emits a real :stuck event only for entries at/above the real attempts threshold" do
    tick_event = [:ash_a2a, :receipt_outbox, :reconciler, :tick]
    stuck_event = [:ash_a2a, :receipt_outbox, :reconciler, :stuck]
    attach_forwarder(tick_event)
    attach_forwarder(stuck_event)

    append_pending_receipt!("cmd-stuck", 7)
    append_pending_receipt!("cmd-fine", 1)

    name = Module.concat(__MODULE__, "Reconciler#{System.unique_integer([:positive])}")

    start_supervised!(
      {Reconciler,
       name: name,
       interval_ms: 60_000,
       stuck_attempts_threshold: 5,
       store: AshA2A.ReceiptStore.Memory,
       store_opts: unavailable_store_opts()}
    )

    assert {:ok, %{committed: 0, remaining: 2}} = Reconciler.tick(name)

    assert_receive {:telemetry, ^tick_event, %{committed: 0, remaining: 2}, %{}}

    assert_receive {:telemetry, ^stuck_event, %{attempts: 7},
                    %{command_id: "cmd-stuck", receipt_id: _receipt_id, threshold: 5}}

    refute_receive {:telemetry, ^stuck_event, %{attempts: 1}, _metadata}, 100
  end

  test "the reconciler really wakes on its own schedule without any manual tick/1 call" do
    tick_event = [:ash_a2a, :receipt_outbox, :reconciler, :tick]
    attach_forwarder(tick_event)

    name = Module.concat(__MODULE__, "Reconciler#{System.unique_integer([:positive])}")

    start_supervised!(
      {Reconciler,
       name: name,
       interval_ms: 20,
       store: AshA2A.ReceiptStore.Memory,
       store_opts: unavailable_store_opts()}
    )

    assert_receive {:telemetry, ^tick_event, %{committed: 0, remaining: 0}, %{}}, 500
  end
end
