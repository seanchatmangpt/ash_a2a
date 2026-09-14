defmodule AshA2A.ReceiptStoreEkvTest do
  @moduledoc """
  Exercises `AshA2A.ReceiptStore.Ekv` against a real, on-disk `EKV` instance
  -- started via `start_supervised!/1` with a real temp `data_dir` under
  `System.tmp_dir!/0` and `cluster_size: 1`, the exact same real-local-EKV
  pattern already used by
  `test/ash_a2a_runtime_providers_integration_test.exs` -- rather than any
  mock/stub of `EKV` or of the `AshA2A.ReceiptStore` behaviour. No
  Mock/mox/patch/monkeypatch anywhere in this file.
  """

  use ExUnit.Case, async: false

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Command, CommandBus, Identity, Receipt}
  alias AshA2A.ReceiptStore.{Ekv, Memory}
  alias AshA2A.Test.Fixture.Echo

  setup do
    ekv_name = :"ash_a2a_receipt_ekv_test_#{System.unique_integer([:positive])}"

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "ash_a2a_receipt_store_ekv_test_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(data_dir) end)

    # cluster_size: 1 -- a real single-voter setup, sufficient for these
    # tests; mirrors test/ash_a2a_runtime_providers_integration_test.exs's
    # real local EKV setup exactly.
    start_supervised!({EKV, name: ekv_name, data_dir: data_dir, cluster_size: 1})

    %{store_opts: [name: ekv_name]}
  end

  defp real_command(command_id, opts \\ []) do
    Command.new("AshA2A.Test.Fixture.Echo.read",
      command_id: command_id,
      agent_id: Keyword.get(opts, :agent_id, "agent-1"),
      principal_id: Keyword.get(opts, :principal_id, "anonymous"),
      input: Keyword.get(opts, :input, %{})
    )
  end

  defp real_receipt(command, execution_id, opts \\ []) do
    reply = Keyword.get(opts, :reply, {:reply, %{ok: true}})
    Receipt.from_reply(command, execution_id, :observe, reply)
  end

  describe "AshA2A.ReceiptStore.Ekv real disk-backed claim/commit/fetch" do
    test "declares itself durable via a real durable?/0 function" do
      assert Ekv.durable?()
    end

    test "claim -> commit -> fetch round-trips through real on-disk storage", %{
      store_opts: store_opts
    } do
      command = real_command("ekv-roundtrip-1")

      assert {:execute, %Identity{kind: :execution} = execution_id} =
               Ekv.claim(command, store_opts)

      receipt = real_receipt(command, execution_id)

      assert :ok = Ekv.commit(receipt, store_opts)

      assert {:ok, fetched} = Ekv.fetch(command.command_id, store_opts)
      assert fetched.receipt_id == receipt.receipt_id
      assert fetched.command_id == command.command_id
      assert fetched.execution_id == execution_id
      refute fetched.replayed?
    end

    test "fetch on an unclaimed command id returns :error", %{store_opts: store_opts} do
      unclaimed_id = Identity.command("ekv-never-claimed")
      assert :error = Ekv.fetch(unclaimed_id, store_opts)
    end

    test "a claimed-but-not-yet-committed command id is :in_flight", %{store_opts: store_opts} do
      command = real_command("ekv-in-flight-1")

      assert {:execute, _execution_id} = Ekv.claim(command, store_opts)

      # Same id, same fingerprint (identical command content), but nothing
      # has been committed yet -- Memory's handle_call/{:claim, ...} clause
      # for this exact same-fingerprint/no-receipt-yet case replies
      # {:error, :in_flight}; this store must decide the same way.
      same_command_again = real_command("ekv-in-flight-1")
      assert {:error, :in_flight} = Ekv.claim(same_command_again, store_opts)
    end

    test "same-id/same-fingerprint replays the already-committed receipt, no second claim", %{
      store_opts: store_opts
    } do
      command = real_command("ekv-replay-1")

      assert {:execute, execution_id} = Ekv.claim(command, store_opts)
      receipt = real_receipt(command, execution_id)
      assert :ok = Ekv.commit(receipt, store_opts)

      # A real retry: identical command_id and fingerprint (same input).
      retry_command = real_command("ekv-replay-1")

      assert {:replay, replayed} = Ekv.claim(retry_command, store_opts)
      assert replayed.receipt_id == receipt.receipt_id
      assert replayed.replayed?
    end

    test "same-id/different-fingerprint is a real :command_conflict", %{store_opts: store_opts} do
      command = real_command("ekv-conflict-1", input: %{})
      assert {:execute, execution_id} = Ekv.claim(command, store_opts)
      receipt = real_receipt(command, execution_id)
      assert :ok = Ekv.commit(receipt, store_opts)

      conflicting_command = real_command("ekv-conflict-1", input: %{other: true})
      assert {:error, :command_conflict} = Ekv.claim(conflicting_command, store_opts)
    end

    test "commit on an unclaimed command id is refused", %{store_opts: store_opts} do
      command = real_command("ekv-unclaimed-commit-1")
      execution_id = Identity.execution(Ash.UUIDv7.generate())
      receipt = real_receipt(command, execution_id)

      assert {:error, :unclaimed_command} = Ekv.commit(receipt, store_opts)
    end

    test "data survives a real EKV process restart against the same data_dir" do
      ekv_name = :"ash_a2a_receipt_ekv_restart_test_#{System.unique_integer([:positive])}"

      data_dir =
        Path.join(
          System.tmp_dir!(),
          "ash_a2a_receipt_store_ekv_restart_test_#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> File.rm_rf!(data_dir) end)

      ekv_opts = [name: ekv_name, data_dir: data_dir, cluster_size: 1]
      store_opts = [name: ekv_name]
      # EKV.child_spec/1 derives id: {EKV, name} -- unique per this test's
      # unique_integer-suffixed ekv_name, and the same id used below to stop
      # and restart the exact same logical child.
      child_id = {EKV, ekv_name}

      pid1 = start_supervised!({EKV, ekv_opts})
      command = real_command("ekv-restart-survives-1")

      assert {:execute, execution_id} = Ekv.claim(command, store_opts)
      receipt = real_receipt(command, execution_id)
      assert :ok = Ekv.commit(receipt, store_opts)

      # Stop the real EKV process entirely (not just the logical entry) and
      # start a brand new one against the same real on-disk data_dir --
      # proving persistence is on disk, not just in this process's memory.
      :ok = stop_supervised(child_id)
      refute Process.alive?(pid1)

      start_supervised!({EKV, ekv_opts})

      assert {:ok, fetched} = Ekv.fetch(command.command_id, store_opts)
      assert fetched.receipt_id == receipt.receipt_id
    end
  end

  describe "standing marking via a real AshA2A.CommandBus.run/4 call" do
    test "a receipt committed through AshA2A.ReceiptStore.Ekv ends up standing: :durable", %{
      store_opts: store_opts
    } do
      command =
        Command.new("AshA2A.Test.Fixture.Echo.read",
          command_id: "ekv-command-bus-durable-1",
          agent_id: "agent-1",
          principal_id: "anonymous",
          input: %{}
        )

      message = data_message(%{})

      assert {:ok, receipt} =
               CommandBus.run(command, message, Echo, store: Ekv, store_opts: store_opts)

      assert receipt.standing == :durable
      assert receipt.status == :completed

      assert {:ok, stored} = Ekv.fetch(command.command_id, store_opts)
      assert stored.standing == :durable
    end

    test "a receipt committed through the default AshA2A.ReceiptStore.Memory still ends up standing: :observed (no regression)" do
      name = Module.concat(__MODULE__, "MemoryStore#{System.unique_integer([:positive])}")
      start_supervised!({Memory, name: name})

      command =
        Command.new("AshA2A.Test.Fixture.Echo.read",
          command_id: "memory-command-bus-observed-1",
          agent_id: "agent-1",
          principal_id: "anonymous",
          input: %{}
        )

      message = data_message(%{})

      assert {:ok, receipt} =
               CommandBus.run(command, message, Echo, store: Memory, store_opts: [name: name])

      assert receipt.standing == :observed
      assert receipt.status == :completed

      assert {:ok, stored} = Memory.fetch(command.command_id, name: name)
      assert stored.standing == :observed
    end
  end
end
