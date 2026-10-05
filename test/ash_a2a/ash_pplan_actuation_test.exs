# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.AshPPlanActuationTest do
  @moduledoc """
  Chicago non-mock integration court verifying the actuation handoff between
  `AshPPlan` and `AshA2A`:

    1. `AshPPlan.Reactor.Steps.Actuate` constructs an actuation intent descriptor
       under authority ceiling `:construct`, with `executed?: false` (never actuating).
    2. The constructed intent is passed to `AshA2A.Reactor.CommandWorkflow` (or
       `AshA2A.CommandBus`) which enforces the Two-Port Gate, checks authority tokens,
       executes the command, and commits an immutable `AshA2A.Receipt` ($A = \\mu(O^*), R = receipt(A)$).
    3. An unauthorized intent is refused at the gate and does not actuate.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Identity, Receipt, ReceiptStore}
  alias AshA2A.Test.Fixture.{Item, ItemDomain}

  test "AshPPlan.Reactor.Steps.Actuate builds intent descriptor without executing" do
    # Run AshPPlan.Reactor.Steps.Actuate directly or in a Reactor step
    args = %{target: "inventory", action: "create_item", count: 1}
    options = [name: :ship_order]

    assert {:ok, intent} = AshPPlan.Reactor.Steps.Actuate.run(args, %{}, options)

    # Authority ceiling is :construct; executed? is always false
    assert intent.authority == :construct
    assert intent.executed? == false
    assert intent.intent == :ship_order
    assert intent.arguments == args
  end

  test "AshPPlan intent is actuated and receipted by AshA2A.Reactor.CommandWorkflow with valid authority" do
    # Step 1: ash_pplan constructs intent descriptor
    item_label = "pplan-actuated-item-#{System.unique_integer([:positive])}"
    args = %{label: item_label}
    assert {:ok, intent} = AshPPlan.Reactor.Steps.Actuate.run(args, %{}, name: :create_item)

    refute intent.executed?
    assert intent.authority == :construct

    # Step 2: Handoff to AshA2A for lawful DO actuation
    command_id = "pplan-actuation-#{System.unique_integer([:positive])}"
    capability_id = "AshA2A.Test.Fixture.Item.create"
    principal = Identity.principal("pplan-subject-#{System.unique_integer([:positive])}")

    authority =
      Authority.new(principal, capability_id,
        token_id: "pplan-auth-token-#{System.unique_integer([:positive])}"
      )

    workflow_inputs = %{
      capability_id: capability_id,
      agent_id: "ash-pplan-planner",
      principal_id: principal,
      command_input: intent.arguments,
      resource_or_domain: Item,
      message: data_message(Map.new(intent.arguments, fn {k, v} -> {to_string(k), v} end)),
      authority: authority,
      command_id: command_id
    }

    assert {:ok, %Receipt{} = receipt} =
             Reactor.run(AshA2A.Reactor.CommandWorkflow, workflow_inputs, %{})

    # Step 3: Verify execution receipt
    assert receipt.command_id == Identity.command(command_id)
    assert receipt.status == :completed
    assert receipt.consequence == :change
    refute receipt.replayed?

    # Verify state was mutated in ETS
    assert {:ok, items} = Ash.read(Item, domain: ItemDomain)
    assert Enum.any?(items, &(&1.label == item_label))

    # Verify receipt is in durable/memory store
    assert {:ok, stored} = ReceiptStore.Memory.fetch(Identity.command(command_id), [])
    assert stored.receipt_id == receipt.receipt_id
  end

  test "AshPPlan intent without authority is refused at the gate and never actuated" do
    item_label = "pplan-unauthorized-item-#{System.unique_integer([:positive])}"
    args = %{label: item_label}
    assert {:ok, intent} = AshPPlan.Reactor.Steps.Actuate.run(args, %{}, name: :create_item)

    command_id = "pplan-unauthorized-#{System.unique_integer([:positive])}"
    capability_id = "AshA2A.Test.Fixture.Item.create"
    principal = Identity.principal("pplan-unauthorized-subject-#{System.unique_integer([:positive])}")

    # No authority token provided for a :change consequence
    workflow_inputs = %{
      capability_id: capability_id,
      agent_id: "ash-pplan-planner",
      principal_id: principal,
      command_input: intent.arguments,
      resource_or_domain: Item,
      message: data_message(Map.new(intent.arguments, fn {k, v} -> {to_string(k), v} end)),
      authority: nil,
      command_id: command_id
    }

    assert {:error, errors} = Reactor.run(AshA2A.Reactor.CommandWorkflow, workflow_inputs, %{})
    assert refusal_code(errors) in [:authority_required, :unauthorized_path, :refused_authority]

    # No receipt stored
    assert :error = ReceiptStore.Memory.fetch(Identity.command(command_id), [])

    # No state changed in ETS
    assert {:ok, items} = Ash.read(Item, domain: ItemDomain)
    refute Enum.any?(items, &(&1.label == item_label))
  end

  defp refusal_code(errors) do
    errors
    |> List.wrap()
    |> Enum.flat_map(&flatten_error/1)
    |> Enum.find_value(fn
      %{code: code} -> code
      _ -> nil
    end)
  end

  defp flatten_error(%Reactor.Error.Invalid.RunStepError{error: inner}),
    do: [inner | flatten_error(inner)]

  defp flatten_error(%{errors: nested}) when is_list(nested),
    do: Enum.flat_map(nested, &flatten_error/1)

  defp flatten_error(other), do: [other]
end
