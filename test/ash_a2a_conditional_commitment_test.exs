defmodule AshA2AConditionalCommitmentTest do
  use ExUnit.Case, async: true

  alias AshA2A.{Authority, Command, ConditionalCommitment, Identity, Receipt}

  defp command(opts \\ []) do
    capability = "AshA2A.Test.Fixture.Item.create"
    principal = Identity.principal("conditional-user")

    authority =
      if Keyword.get(opts, :authorized, false) do
        Authority.new(principal, capability, token_id: "conditional-grant")
      end

    Command.new(capability,
      command_id: Keyword.get(opts, :command_id, "conditional-command"),
      agent_id: "conditional-agent",
      principal_id: principal,
      authority: authority,
      input: %{label: "conditional"}
    )
  end

  defp pending_receipt(command) do
    Receipt.pending(
      command,
      Identity.execution("conditional-execution"),
      :change
    )
  end

  test "proposal is not authority and cannot cross DO boundary" do
    decision = command() |> ConditionalCommitment.classify()

    assert decision.standing == :proposed
    refute decision.authorized?
    refute decision.prepared?
    refute decision.ready_for_do?
  end

  test "authority alone is not a prepared consequence" do
    decision = command(authorized: true) |> ConditionalCommitment.classify()

    assert decision.standing == :authorized
    assert decision.authorized?
    refute decision.prepared?
    refute decision.ready_for_do?
  end

  test "matching authority plus exact pending receipt is prepared for BRCE" do
    command = command(authorized: true)
    receipt = pending_receipt(command)

    decision = ConditionalCommitment.classify(command, receipt)

    assert decision.standing == :prepared
    assert decision.authorized?
    assert decision.prepared?
    assert decision.ready_for_do?
    assert ConditionalCommitment.ready_for_do?(command, receipt)
  end

  test "prepared receipt never manufactures missing authority" do
    command = command()
    receipt = pending_receipt(command)

    decision = ConditionalCommitment.classify(command, receipt)

    assert decision.standing == :refused
    assert decision.refusal_code == :authority_required
    refute decision.ready_for_do?
  end

  test "receipt for another command is a typed refusal" do
    command = command(authorized: true)
    other = command(authorized: true, command_id: "other-command")
    receipt = pending_receipt(other)

    decision = ConditionalCommitment.classify(command, receipt)

    assert decision.standing == :refused
    assert decision.refusal_code == :command_id_mismatch
    refute decision.ready_for_do?
  end
end
