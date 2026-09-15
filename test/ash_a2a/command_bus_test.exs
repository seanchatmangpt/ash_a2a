defmodule AshA2A.CommandBusTest do
  use ExUnit.Case

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Command, CommandBus, Identity, ReceiptStore}
  alias AshA2A.Test.Fixture.{Echo, Item}

  setup do
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
    assert {:error, %{code: :receipt_store_unavailable}} = result

    # The backing process really did go down as part of this test.
    assert GenServer.whereis(Keyword.fetch!(store_opts, :name)) == nil
  end
end
