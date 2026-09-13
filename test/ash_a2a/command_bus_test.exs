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

  test "read command produces a receipt and same command replays without a second claim", %{store_opts: store_opts} do
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

  test "same command id with changed semantic input is rejected by the claim store", %{store_opts: store_opts} do
    one = Command.new("AshA2A.Test.Fixture.Echo.read", command_id: "conflict-1", agent_id: "agent-1", principal_id: "anonymous", input: %{})
    two = Command.new("AshA2A.Test.Fixture.Echo.read", command_id: "conflict-1", agent_id: "agent-1", principal_id: "anonymous", input: %{other: true})
    message = data_message(%{})

    assert {:ok, _} = CommandBus.run(one, message, Echo, store_opts: store_opts)
    assert {:error, %{code: :command_conflict}} = CommandBus.run(two, message, Echo, store_opts: store_opts)
  end

  test "non-read capability requires matching authority before dispatcher entry", %{store_opts: store_opts} do
    command =
      Command.new("AshA2A.Test.Fixture.Item.create",
        command_id: "create-1",
        agent_id: "agent-1",
        principal_id: "subject-1",
        input: %{label: "widget"}
      )

    assert {:error, %{code: :authority_required}} =
             CommandBus.run(command, data_message(%{"label" => "widget"}), Item, store_opts: store_opts)

    assert :error = ReceiptStore.Memory.fetch(command.command_id, store_opts)
  end

  test "matching authority admits a real create and commits its receipt", %{store_opts: store_opts} do
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
             CommandBus.run(command, data_message(%{"label" => "widget"}), Item, store_opts: store_opts)

    assert receipt.status == :completed
    assert receipt.consequence == :change
    assert {:ok, stored} = ReceiptStore.Memory.fetch(command.command_id, store_opts)
    assert stored.receipt_id == receipt.receipt_id
  end
end
