defmodule AshA2A.FlamePlacementTest do
  use ExUnit.Case, async: true

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Command, Execution.FLAME, Identity, Receipt, ReceiptStore, RuntimeReceipt}
  alias AshA2A.Test.Fixture.Echo

  test "missing FLAME provider fails closed without bypassing CommandBus" do
    unless FLAME.available?() do
      command =
        Command.new("AshA2A.Test.Fixture.Echo.read",
          command_id: "flame-read-1",
          agent_id: "agent-1",
          principal_id: "anonymous"
        )

      message = A2A.Message.new_user([A2A.Part.Data.new(%{})])

      assert {:error, {:unsupported, :flame}} =
               FLAME.run(:ash_a2a_pool, command, message, Echo)
    end
  end

  test "FLAME available: real local FLAME.Pool runner routes through CommandBus and receipts a real completed execution" do
    # This is the real happy-path counterpart to the test above. In this
    # environment FLAME.available?() is true (Code.ensure_loaded?(FLAME) and
    # function_exported?(FLAME, :call, 3) both hold), so the "unless
    # available?" branch above never executes its body here -- that test only
    # ever proves the fail-closed branch in THIS environment. This test
    # proves the other branch for real: a genuine FLAME.Pool (FLAME's own
    # documented FLAME.LocalBackend -- "A FLAME.Backend useful for
    # development and testing", deps/flame/lib/flame/local_backend.ex),
    # actually placing and running the closure that calls
    # AshA2A.CommandBus.run/4, with a real receipted reply asserted on the
    # real returned value -- no mocking of FLAME, CommandBus, or the
    # dispatcher.
    assert FLAME.available?()

    pool_name = Module.concat(__MODULE__, "Pool#{System.unique_integer([:positive])}")
    store_name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")

    # NB: `Elixir.FLAME.Pool`, not the bare `FLAME.Pool` -- this module's
    # `alias AshA2A.{..., Execution.FLAME, ...}` above binds the local name
    # `FLAME` to `AshA2A.Execution.FLAME`, so an unqualified `FLAME.Pool`
    # here would resolve to the nonexistent `AshA2A.Execution.FLAME.Pool`
    # instead of the real top-level `FLAME.Pool` GenServer this test needs
    # to start.
    start_supervised!({Elixir.FLAME.Pool, name: pool_name, min: 1, max: 1, max_concurrency: 5})
    start_supervised!({ReceiptStore.Memory, name: store_name})

    command =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "flame-happy-1",
        agent_id: "agent-1",
        principal_id: "anonymous",
        input: %{}
      )

    message = data_message(%{})

    assert {:ok,
            %{
              receipt: %Receipt{} = receipt,
              placement: %RuntimeReceipt{} = placement
            }} =
             FLAME.run(pool_name, command, message, Echo,
               command_bus_opts: [store_opts: [name: store_name]]
             )

    # `receipt` is the real AshA2A.Receipt committed by AshA2A.CommandBus.run/4
    # inside the FLAME-placed closure -- a real completed execution, not a
    # placeholder or an echo of the input.
    assert receipt.command_id == command.command_id
    assert receipt.capability_id == "AshA2A.Test.Fixture.Echo.read"
    assert receipt.consequence == :observe
    assert receipt.status == :completed
    assert receipt.standing == :observed
    refute receipt.replayed?
    assert {:reply, _reply_payload} = receipt.reply

    # The same command_id, replayed a second time through the same store,
    # returns the identical committed receipt -- proving the first call
    # really executed and committed (a placeholder reply would not be
    # replayable in this way).
    assert {:ok, %{receipt: replay_receipt}} =
             FLAME.run(pool_name, command, message, Echo,
               command_bus_opts: [store_opts: [name: store_name]]
             )

    assert replay_receipt.replayed?
    assert replay_receipt.receipt_id == receipt.receipt_id

    # `placement` is the real AshA2A.RuntimeReceipt recorded by
    # AshA2A.Execution.FLAME.run/5 around the FLAME.call/3 placement itself
    # -- observed provider standing for the placement, distinct from (and
    # never conferring) the CommandBus execution receipt above.
    assert placement.provider == :flame
    assert placement.operation == :call
    assert placement.status == :completed
    assert placement.subject == Identity.external(command.command_id)
    assert placement.standing == :observed
    assert {:ok, %Receipt{}} = placement.result
  end
end
