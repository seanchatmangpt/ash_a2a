defmodule AshA2A.Reactor.CommandWorkflowTest do
  @moduledoc """
  Real `Reactor.run/2..4` execution over `AshA2A.Reactor.CommandWorkflow` --
  the actual Reactor DAG-execution/scheduler engine, not a bare function
  call to a `Reactor.Step` callback (which is all
  `test/ash_a2a/lifecycle_reactor_test.exs` exercised before this file).
  Uses the same default, application-supervised `AshA2A.ReceiptStore.Memory`
  process real callers (`AshA2AAgentCommandBusTest`) already rely on --
  every command below carries a globally unique `command_id`
  (`System.unique_integer/1`), so no dedicated per-test store process is
  needed for isolation. No Mock/mox/patch/monkeypatch anywhere in this file.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Identity, Receipt, ReceiptStore}
  alias AshA2A.Test.Fixture.{Echo, Item, ItemDomain}

  test "a real Reactor.run/2 DAG builds a command, routes it through CommandBus, and confirms the committed receipt (:observe)" do
    command_id = "reactor-workflow-read-#{System.unique_integer([:positive])}"

    inputs = %{
      capability_id: "AshA2A.Test.Fixture.Echo.read",
      agent_id: "reactor-workflow-agent",
      principal_id: "anonymous",
      command_input: %{},
      resource_or_domain: Echo,
      message: data_message(%{}),
      authority: nil,
      command_id: command_id
    }

    assert {:ok, %Receipt{} = receipt} =
             Reactor.run(AshA2A.Reactor.CommandWorkflow, inputs, %{})

    assert receipt.command_id == Identity.command(command_id)
    assert receipt.status == :completed
    assert receipt.consequence == :observe
    refute receipt.replayed?

    assert {:ok, stored} = ReceiptStore.Memory.fetch(Identity.command(command_id), [])
    assert stored.receipt_id == receipt.receipt_id
  end

  test "a real Reactor.run/2 DAG admits and commits an authorized consequence-bearing command (:change)" do
    command_id = "reactor-workflow-create-#{System.unique_integer([:positive])}"
    capability_id = "AshA2A.Test.Fixture.Item.create"

    principal =
      Identity.principal("reactor-workflow-subject-#{System.unique_integer([:positive])}")

    authority =
      Authority.new(principal, capability_id,
        token_id: "reactor-workflow-auth-#{System.unique_integer([:positive])}"
      )

    inputs = %{
      capability_id: capability_id,
      agent_id: "reactor-workflow-agent",
      principal_id: principal,
      command_input: %{label: "reactor-workflow-widget"},
      resource_or_domain: Item,
      message: data_message(%{"label" => "reactor-workflow-widget"}),
      authority: authority,
      command_id: command_id
    }

    assert {:ok, %Receipt{} = receipt} =
             Reactor.run(AshA2A.Reactor.CommandWorkflow, inputs, %{})

    assert receipt.status == :completed
    assert receipt.consequence == :change
    refute receipt.replayed?

    assert {:ok, stored} = ReceiptStore.Memory.fetch(Identity.command(command_id), [])
    assert stored.receipt_id == receipt.receipt_id

    assert {:ok, items} = Ash.read(Item, domain: ItemDomain)
    assert Enum.any?(items, &(&1.label == "reactor-workflow-widget"))
  end

  test "the real Reactor engine surfaces CommandBus's real :authority_required refusal for an unauthorized consequence-bearing command -- never a raw unguarded Ash exception, never a silent bypass" do
    command_id = "reactor-workflow-unauth-#{System.unique_integer([:positive])}"
    capability_id = "AshA2A.Test.Fixture.Item.create"
    label = "reactor-workflow-should-never-exist-#{System.unique_integer([:positive])}"

    inputs = %{
      capability_id: capability_id,
      agent_id: "reactor-workflow-agent",
      # A real principal with NO `AshA2A.Authority` admitted for this
      # capability -- the deliberately unauthorized input this test exists
      # to construct.
      principal_id: "reactor-workflow-subject-no-authority",
      command_input: %{label: label},
      resource_or_domain: Item,
      message: data_message(%{"label" => label}),
      authority: nil,
      command_id: command_id
    }

    assert {:error, errors} = Reactor.run(AshA2A.Reactor.CommandWorkflow, inputs, %{})

    # The real refusal CommandBus.admit/2 raises for a :change command with
    # no admitted Authority (lib/ash_a2a/command_bus.ex `defp admit(_command,
    # consequence) when consequence in [:change, :external_do] -> {:error,
    # refusal(:authority_required)}`) must be the real reason the Reactor
    # engine halted on -- found by walking the real
    # `Reactor.Error.Invalid.RunStepError` chain Reactor wraps step failures
    # in, not asserted as an opaque error tuple.
    assert :authority_required = refusal_code(errors)

    # The real CommandBus admission boundary refused this command BEFORE the
    # real Ash dispatcher/action ever ran -- proven two ways, not asserted:
    # no receipt was ever committed for this command_id (CommandBus.admit/2
    # short-circuits before the store is even asked to claim it), and no
    # Item record with this unique label exists in the real ETS-backed
    # data layer.
    assert :error = ReceiptStore.Memory.fetch(Identity.command(command_id), [])

    assert {:ok, items} = Ash.read(Item, domain: ItemDomain)
    refute Enum.any?(items, &(&1.label == label))
  end

  # Reactor wraps every step-level `{:error, reason}` in a real
  # `Reactor.Error.Invalid.RunStepError` (`error.error` holding the original
  # reason), then Reactor's own Splode-based error aggregation may nest that
  # inside a list and/or a composite `Reactor.Error.Invalid` -- this walks
  # that real, observed shape rather than assuming one fixed level of
  # nesting.
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
