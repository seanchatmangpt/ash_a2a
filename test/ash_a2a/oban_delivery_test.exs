defmodule AshA2A.ObanDeliveryTest do
  use ExUnit.Case, async: true

  alias AshA2A.{Authority, Command, Delivery, Identity}

  test "provider delivery id remains distinct from A2A task id" do
    command =
      Command.new("Example.Resource.read",
        command_id: "command-1",
        agent_id: "agent-1",
        principal_id: "principal-1",
        task_id: "task-1"
      )

    delivery = Delivery.new(:oban, command, provider_ref: 42, status: :scheduled)

    assert Delivery.task_key(delivery) == "task:task-1"
    assert delivery.provider_ref == 42
    refute delivery.provider_ref == Delivery.task_key(delivery)
  end

  test "Oban payload carries command references but not execution identity" do
    principal = Identity.principal("principal-1")
    authority = Authority.new(principal, "Example.Resource.update", token_id: "auth-1")

    command =
      Command.new("Example.Resource.update",
        command_id: "command-2",
        agent_id: "agent-1",
        principal_id: principal,
        task_id: "task-2",
        authority: authority,
        input: %{value: 7}
      )

    payload = Delivery.Oban.payload(command)

    assert payload["command_id"] == "command:command-2"
    assert payload["task_id"] == "task:task-2"
    assert payload["authority_token_id"] == "runtime:auth-1"
    assert payload["fingerprint"] == command.fingerprint
    refute Map.has_key?(payload, "execution_id")
  end
end
