defmodule AshA2A.CommandBusCrashWindowChicagoTest do
  @moduledoc """
  Chicago-school falsifier for the remaining A2A-2601 crash window.

  A separate OS BEAM performs one real HTTP consequence and is killed after
  the receiver acknowledges it but before CommandBus can finalize the pending
  receipt. This BEAM then reconciles the persisted anchor into a fresh primary
  store and proves replay cannot perform the external consequence a second
  time.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.{CommandBus, Receipt, ReceiptOutbox, ReceiptStore}
  alias AshA2A.Test.Fixture.ReceiptCrashWindow.{ExternalDo, Runner}

  defmodule Receiver do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    post "/do" do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"operation_id" => operation_id} = Jason.decode!(body)

      Agent.update(Receiver.Store, fn operation_ids ->
        [operation_id | operation_ids]
      end)

      Plug.Conn.send_resp(conn, 204, "")
    end

    match(_) do
      Plug.Conn.send_resp(conn, 404, "not found")
    end
  end

  setup do
    {:ok, _agent} = Agent.start_link(fn -> [] end, name: Receiver.Store)

    port = Enum.random(25_000..25_999)
    {:ok, _bandit} = Bandit.start_link(plug: Receiver, port: port, ip: {127, 0, 0, 1})

    outbox_dir =
      Path.join(
        System.tmp_dir!(),
        "ash-a2a-crash-window-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:ash_a2a, :receipt_outbox_dir, outbox_dir)

    on_exit(fn ->
      Application.delete_env(:ash_a2a, :receipt_outbox_dir)
      File.rm_rf!(outbox_dir)
    end)

    {:ok,
     url: "http://127.0.0.1:#{port}",
     outbox_dir: outbox_dir,
     command_id: "receipt-crash-window-#{System.unique_integer([:positive])}"}
  end

  test "acknowledged external DO survives runner death as pending evidence and replay cannot DO twice",
       %{url: url, outbox_dir: outbox_dir, command_id: command_id} do
    expression =
      "AshA2A.Test.Fixture.ReceiptCrashWindow.Runner.run!(" <>
        "#{inspect(url)}, #{inspect(outbox_dir)}, #{inspect(command_id)})"

    {_output, exit_code} =
      System.cmd("mix", ["run", "-e", expression],
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    refute exit_code == 0
    assert Agent.get(Receiver.Store, &Enum.reverse/1) == [command_id]

    assert [
             %Receipt{
               status: :pending,
               consequence: :external_do,
               command_id: anchor_command_id
             } = anchor
           ] = ReceiptOutbox.entries()

    assert anchor_command_id == Runner.command(url, command_id).command_id

    store_name =
      Module.concat(__MODULE__, "RestartedStore#{System.unique_integer([:positive])}")

    {:ok, _pid} = GenServer.start(ReceiptStore.Memory, %{}, name: store_name)
    store_opts = [name: store_name]

    assert {:ok, %{committed: 1, remaining: 0}} =
             CommandBus.reconcile_outboxed_receipts(ReceiptStore.Memory, store_opts)

    assert ReceiptOutbox.count() == 0
    assert {:ok, stored} = ReceiptStore.Memory.fetch(anchor.command_id, store_opts)
    assert stored.receipt_id == anchor.receipt_id
    assert stored.status == :pending

    assert {:ok, replayed} =
             CommandBus.run(
               Runner.command(url, command_id),
               Runner.message(url, command_id),
               ExternalDo,
               store: ReceiptStore.Memory,
               store_opts: store_opts
             )

    assert replayed.replayed? == true
    assert replayed.status == :pending
    assert replayed.receipt_id == anchor.receipt_id

    assert Agent.get(Receiver.Store, &Enum.reverse/1) == [command_id]
  end
end
