defmodule AshA2AArchitectureVerifierTest do
  @moduledoc """
  Direct ExUnit coverage of `AshA2A.ArchitectureVerifier`'s four real
  architecture checks -- the same production code `mix
  ash_a2a.verify_architecture` (`lib/mix/tasks/ash_a2a.verify_architecture.ex`)
  runs from a shell, called here directly so each check's real return value
  is asserted on individually rather than only trusting its own self-reported
  `:pass`/`:fail` summary. No Mock/mox/patch/monkeypatch anywhere in this
  file: every assertion below is against the real, unmodified
  `AshA2A.Info`/`AshA2A.Command`/`AshA2A.CommandBus` API and the real
  compiled `AshA2A.ArchitectureVerifier.Fixture.Resource`
  (`lib/ash_a2a/architecture_verifier.ex`).
  """

  use ExUnit.Case, async: true

  alias AshA2A.ArchitectureVerifier
  alias AshA2A.ArchitectureVerifier.Fixture.Resource
  alias AshA2A.{Command, CommandBus, Info}

  test "checks/0 reports all four real architecture invariants as passing" do
    results = ArchitectureVerifier.checks()

    assert length(results) == 4
    assert Enum.all?(results, &(&1.status == :pass)), inspect(results)
    assert Enum.all?(results, &(&1.detail != ""))
  end

  test "check 1: AshA2A.Info.capability_index/1 returns a real, non-nil list for the fixture resource" do
    result = ArchitectureVerifier.check_capability_index_derivable()
    assert result.status == :pass

    # Re-derive the same real call directly and assert on its actual state,
    # not just the wrapped summary above.
    index = Info.capability_index(Resource)
    assert is_list(index)
    refute index == []
    assert Enum.any?(index, &(&1.action == :create))
    assert Enum.any?(index, &(&1.action == :probe))
  end

  test "check 2: a real :unknown-consequence skill is refused by CommandBus.admit before dispatch" do
    result = ArchitectureVerifier.check_unknown_consequence_refused()
    assert result.status == :pass

    {:ok, probe_skill} =
      Resource
      |> Info.capability_index()
      |> Enum.find(&(&1.action == :probe))
      |> then(&{:ok, &1})

    assert probe_skill.consequence == :unknown

    command =
      Command.new(probe_skill.id,
        command_id: "test-unknown-#{System.unique_integer([:positive])}",
        agent_id: "test-agent",
        principal_id: "test-principal",
        input: %{}
      )

    message = A2A.Message.new_user([A2A.Part.Data.new(%{})])

    assert {:error, %{code: :consequence_unclassified}} =
             CommandBus.run(command, message, Resource)
  end

  test "check 3: a real :change-consequence skill with no Authority is refused with :authority_required" do
    result = ArchitectureVerifier.check_change_requires_authority()
    assert result.status == :pass

    {:ok, create_skill} =
      Resource
      |> Info.capability_index()
      |> Enum.find(&(&1.action == :create))
      |> then(&{:ok, &1})

    assert create_skill.consequence == :change

    command =
      Command.new(create_skill.id,
        command_id: "test-change-#{System.unique_integer([:positive])}",
        agent_id: "test-agent",
        principal_id: "test-principal",
        input: %{}
      )

    message = A2A.Message.new_user([A2A.Part.Data.new(%{})])

    assert {:error, %{code: :authority_required}} = CommandBus.run(command, message, Resource)
  end

  test "check 4: Command.fingerprint/1 is stable for identical content and diverges for changed input" do
    result = ArchitectureVerifier.check_fingerprint_invariants()
    assert result.status == :pass

    shared_opts = [
      command_id: "same-command-id",
      agent_id: "test-agent",
      principal_id: "test-principal"
    ]

    same_a = Command.new("test.capability", Keyword.put(shared_opts, :input, %{n: 1}))
    same_b = Command.new("test.capability", Keyword.put(shared_opts, :input, %{n: 1}))
    different = Command.new("test.capability", Keyword.put(shared_opts, :input, %{n: 2}))

    assert same_a.command_id == same_b.command_id
    assert same_a.command_id == different.command_id

    assert same_a.fingerprint == same_b.fingerprint
    assert same_a.fingerprint == Command.fingerprint(same_a)

    refute same_a.fingerprint == different.fingerprint
  end
end
