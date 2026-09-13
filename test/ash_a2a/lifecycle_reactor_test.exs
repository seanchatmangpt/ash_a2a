defmodule AshA2A.LifecycleReactorTest do
  use ExUnit.Case

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Command, TaskLifecycle}
  alias AshA2A.Test.Fixture.Echo

  test "A2A task vocabulary is explicit without locally inventing transitions" do
    assert TaskLifecycle.states() == [
             :submitted,
             :working,
             :input_required,
             :auth_required,
             :completed,
             :failed,
             :canceled,
             :rejected
           ]
  end

  test "Reactor step routes through CommandBus and returns its receipt" do
    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: name})

    command =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "reactor-read-1",
        agent_id: "reactor-agent",
        principal_id: "anonymous"
      )

    arguments = %{command: command, message: data_message(%{}), resource_or_domain: Echo}
    options = [command_bus_opts: [store_opts: [name: name]]]

    assert {:ok, receipt} = AshA2A.Reactor.ExecuteCommand.run(arguments, %{}, options)
    assert receipt.command_id == command.command_id
    assert receipt.status == :completed
  end
end
