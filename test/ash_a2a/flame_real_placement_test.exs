defmodule AshA2A.FlameRealPlacementTest do
  @moduledoc """
  Proves `AshA2A.Execution.FLAME.run/5` genuinely dispatches a real
  `AshA2A.CommandBus.run/4` call onto a real FLAME-placed process, closing
  the gap a prior audit found: `test/ash_a2a/flame_placement_test.exs` and
  `test/ash_a2a_runtime_providers_integration_test.exs` both only assert
  `FLAME.available?()`, and since the real `:flame` dependency is present
  `available?/0` is always `true` in this environment -- so the
  real-provider-guarded body of `FLAME.run/5` (the `if available?() do ...`
  branch) never actually executed in any prior test run in this repo.

  This test starts a real `FLAME.Pool` backed by `FLAME.LocalBackend` --
  the backend the `:flame` dependency itself ships and documents for this
  exact purpose:

      > By default, the `FLAME.LocalBackend` is used, which is great for
      > development and test environments, as you can have your code simply
      > execute locally in most cases and worry about scaling the operation
      > only in production.
      (deps/flame/lib/flame.ex, "Backends" section of the module doc)

  `FLAME.LocalBackend.remote_spawn_monitor/2`
  (deps/flame/lib/flame/local_backend.ex) implements FLAME's remote
  placement contract with a real `spawn_monitor/1` on this same BEAM node
  instead of a cloud machine -- no cloud credentials, no mocked backend, no
  substitute `FLAME.Backend` implementation written for this test. FLAME's
  own `FLAME.Runner.remote_call/5` (deps/flame/lib/flame/runner.ex) confirms
  the wrapped closure runs inside that spawned process ("# This runs on the
  remote node"), so the second test below captures the real executing pid
  via a synchronous `:telemetry` handler (telemetry handlers run in the
  caller's process, not a separate one) to prove the dispatch genuinely
  happened on a process distinct from the test process -- not merely that
  `CommandBus.run/4` was called inline.

  No `:flame, :backend` application config exists anywhere in this repo
  (`config/`), so `FLAME.Pool` would default to `FLAME.LocalBackend` even
  without the explicit `backend:` option below; it is passed explicitly here
  only so this test is not silently affected by a future default change.
  """

  use ExUnit.Case, async: false

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Execution.FLAME, as: Placement
  alias AshA2A.{Command, Receipt, ReceiptStore, RuntimeReceipt}
  alias AshA2A.Test.Fixture.Echo

  setup do
    store_name = :"flame_real_placement_store_#{System.unique_integer([:positive])}"
    start_supervised!({ReceiptStore.Memory, name: store_name})

    pool_name = :"flame_real_placement_pool_#{System.unique_integer([:positive])}"

    start_supervised!(
      {FLAME.Pool,
       name: pool_name,
       min: 0,
       max: 1,
       max_concurrency: 5,
       backend: FLAME.LocalBackend,
       timeout: 5_000,
       boot_timeout: 5_000,
       idle_shutdown_after: 5_000}
    )

    %{pool: pool_name, store_opts: [name: store_name]}
  end

  test "run/5 dispatches through a real local-backend FLAME pool and returns real receipts", %{
    pool: pool,
    store_opts: store_opts
  } do
    assert Placement.available?()

    command =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "flame-real-read-1",
        agent_id: "agent-1",
        principal_id: "anonymous",
        input: %{}
      )

    message = data_message(%{})

    assert {:ok, %{receipt: receipt, placement: placement}} =
             Placement.run(pool, command, message, Echo,
               command_bus_opts: [store_opts: store_opts]
             )

    # The real AshA2A.CommandBus.run/4 outcome, produced on the FLAME-placed
    # process and returned back through FLAME.call/3 to this test process.
    assert %Receipt{status: :completed, consequence: :observe} = receipt
    refute receipt.replayed?

    # The real FLAME placement evidence AshA2A.Execution.FLAME.run/5 records
    # alongside the command receipt -- observed provider standing only.
    assert %RuntimeReceipt{provider: :flame, operation: :call, status: :completed} = placement
    assert placement.standing == :observed

    # Same command id replayed through the same real pool: the claim store
    # (not FLAME) is what makes this idempotent, proving FLAME placement
    # never bypasses CommandBus's own replay semantics.
    assert {:ok, %{receipt: replay_receipt}} =
             Placement.run(pool, command, message, Echo,
               command_bus_opts: [store_opts: store_opts]
             )

    assert replay_receipt.replayed?
    assert replay_receipt.receipt_id == receipt.receipt_id
  end

  test "the dispatched command genuinely executes on a distinct real FLAME-placed process", %{
    pool: pool,
    store_opts: store_opts
  } do
    test_pid = self()
    handler_id = "flame-real-placement-#{System.unique_integer([:positive])}"

    # :telemetry.execute/3 runs attached handlers synchronously in the
    # process that called it (AshA2A.CommandBus.emit_receipt/1, called from
    # inside AshA2A.CommandBus.run/4) -- so capturing self() inside this
    # handler captures the real pid CommandBus.run/4 actually executed in,
    # with no mock standing in for FLAME's own placement.
    :telemetry.attach(
      handler_id,
      [:ash_a2a, :receipt, :committed],
      fn _event, _measurements, _metadata, _config ->
        send(test_pid, {:executed_on, self()})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    command =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "flame-real-read-2",
        agent_id: "agent-1",
        principal_id: "anonymous",
        input: %{}
      )

    message = data_message(%{})

    assert {:ok, %{receipt: %Receipt{status: :completed}}} =
             Placement.run(pool, command, message, Echo,
               command_bus_opts: [store_opts: store_opts]
             )

    assert_receive {:executed_on, executor_pid}, 1_000
    assert is_pid(executor_pid)
    refute executor_pid == test_pid
  end
end
