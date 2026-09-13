defmodule AshA2A.CommandContractTest do
  use ExUnit.Case, async: true

  alias AshA2A.{Authority, Command, Identity}

  test "machine identities remain typed and non-interchangeable" do
    agent = Identity.agent("worker-7")
    task = Identity.task("worker-7")

    assert agent.kind == :agent
    assert task.kind == :task
    refute agent == task
    assert Identity.external(agent) == "agent:worker-7"
    assert Identity.external(task) == "task:worker-7"
  end

  test "authority is bound to one admitted principal and capability" do
    principal = Identity.principal("subject-1")
    authority = Authority.new(principal, "Example.Resource.read", token_id: "auth-1")

    command =
      Command.new("Example.Resource.read",
        command_id: "command-1",
        agent_id: "agent-1",
        principal_id: principal,
        authority: authority,
        input: %{id: 1}
      )

    assert Authority.admits?(authority, command)

    other = %{command | capability_id: "Example.Resource.update"}
    refute Authority.admits?(authority, other)
  end

  test "semantic fingerprint is stable across transport retry identity and timestamp" do
    principal = Identity.principal("subject-1")
    authority = Authority.new(principal, "Example.Resource.read", token_id: "auth-1")
    common = [agent_id: "agent-1", principal_id: principal, authority: authority, input: %{id: 1}]

    one = Command.new("Example.Resource.read", Keyword.merge(common, command_id: "command-1"))
    two = Command.new("Example.Resource.read", Keyword.merge(common, command_id: "command-2"))

    assert one.command_id != two.command_id
    assert one.fingerprint == two.fingerprint
  end

  test "fingerprint changes when consequence-bearing semantic input changes" do
    principal = Identity.principal("subject-1")
    common = [agent_id: "agent-1", principal_id: principal]

    one = Command.new("Example.Resource.update", Keyword.merge(common, input: %{value: 1}))
    two = Command.new("Example.Resource.update", Keyword.merge(common, input: %{value: 2}))

    refute one.fingerprint == two.fingerprint
  end
end
