defmodule AshA2ACommitmentTelemetryTest do
  use ExUnit.Case, async: false

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Command, CommandBus, Identity}
  alias AshA2A.Test.Fixture.{Echo, Item}

  setup do
    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: name})

    handler_id = {:conditional_commitment, System.unique_integer([:positive])}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:ash_a2a, :command_bus, :commitment],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:commitment, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    %{store_opts: [name: name]}
  end

  test "consequential command emits authorized then prepared standing before DO", %{
    store_opts: store_opts
  } do
    principal = Identity.principal("commitment-telemetry-user")
    capability = "AshA2A.Test.Fixture.Item.create"
    authority = Authority.new(principal, capability, token_id: "commitment-telemetry-grant")

    command =
      Command.new(capability,
        command_id: "commitment-telemetry-command",
        agent_id: "commitment-telemetry-agent",
        principal_id: principal,
        authority: authority,
        input: %{label: "commitment-telemetry"}
      )

    assert {:ok, receipt} =
             CommandBus.run(
               command,
               data_message(%{"label" => "commitment-telemetry"}),
               Item,
               store_opts: store_opts
             )

    assert receipt.status == :completed
    assert receipt.consequence == :change

    assert_receive {:commitment, admitted}, 1_000
    assert admitted.transition == :admission
    assert admitted.consequence == :change
    assert admitted.commitment_standing == :authorized
    assert admitted.commitment_authorized
    refute admitted.commitment_prepared
    refute admitted.commitment_ready_for_do
    assert is_binary(admitted.commitment_digest)
    assert admitted.prepared_receipt_id == nil

    assert_receive {:commitment, prepared}, 1_000
    assert prepared.transition == :prepare
    assert prepared.consequence == :change
    assert prepared.commitment_standing == :prepared
    assert prepared.commitment_authorized
    assert prepared.commitment_prepared
    assert prepared.commitment_ready_for_do
    assert is_binary(prepared.prepared_receipt_id)
    refute prepared.commitment_digest == admitted.commitment_digest
  end

  test "observe commands do not emit consequential commitment standing", %{
    store_opts: store_opts
  } do
    command =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "commitment-observe-command",
        agent_id: "commitment-observe-agent",
        principal_id: "anonymous",
        input: %{}
      )

    assert {:ok, receipt} =
             CommandBus.run(command, data_message(%{}), Echo, store_opts: store_opts)

    assert receipt.consequence == :observe
    refute_receive {:commitment, _metadata}, 50
  end
end
