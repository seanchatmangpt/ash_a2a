defmodule AshA2A.RFC004FenceTest do
  @moduledoc "RFC-SA2A-004 §11.4/§21: forged resolved_skill and forged anchors are refused."
  use ExUnit.Case, async: false

  alias AshA2A.{Authority, BrceAnchor, Command, Dispatcher, Identity, Receipt, ReceiptOutbox}
  alias AshA2A.Chicago.Fixtures.Brce, as: Fx
  alias AshA2A.Chicago.Fixtures.Brce.Ledger

  setup do
    BrceAnchor.clear()
    on_exit(&BrceAnchor.clear/0)
    {:ok, record} = AshA2A.Info.skill(Ledger, :record)
    %{record: record}
  end

  test "forged resolved_skill is refused before the action runs", %{record: record} do
    label = "rfc004-forged-skill-#{System.unique_integer([:positive])}"
    anchor = anchor(record.id)
    :ok = ReceiptOutbox.append(anchor)
    on_exit(fn -> ReceiptOutbox.remove(anchor) end)
    forged = %{record | consequence: :observe}
    :ok = BrceAnchor.put(anchor)

    assert {:error,
            {:skill_lookup, %{code: :capability_mismatch, reason: :resolved_skill_not_in_index}}} =
             Dispatcher.dispatch(:record, message(label), Ledger, [], nil, resolved_skill: forged)

    refute label in Fx.ledger_labels()
  end

  test "forged anchor with no outbox entry is refused", %{record: record} do
    label = "rfc004-forged-anchor-#{System.unique_integer([:positive])}"
    :ok = BrceAnchor.put(anchor(record.id))

    assert {:error,
            {:brce_gate, %{code: :brce_prepared_receipt_required, reason: :anchor_not_durable}}} =
             Dispatcher.dispatch(:record, message(label), Ledger)

    refute label in Fx.ledger_labels()
  end

  test "legitimate path dispatches exactly once", %{record: record} do
    label = "rfc004-legit-#{System.unique_integer([:positive])}"
    anchor = anchor(record.id)
    :ok = ReceiptOutbox.append(anchor)
    on_exit(fn -> ReceiptOutbox.remove(anchor) end)
    :ok = BrceAnchor.put(anchor)

    # A consequence-bearing dispatch is admitted only inside the kernel's dispatcher fence
    # (the W4 DispatchInversion entry), and only with the durable anchor.
    assert {:reply, _} =
             AshA2A.ConsequenceKernel.W4.DispatcherFence.enter(fn ->
               Dispatcher.dispatch(:record, message(label), Ledger, [], nil,
                 resolved_skill: record
               )
             end)

    assert Enum.count(Fx.ledger_labels(), &(&1 == label)) == 1
  end

  test "a durably anchored dispatch outside the kernel fence is refused before the action runs",
       %{record: record} do
    label = "rfc004-nofence-#{System.unique_integer([:positive])}"
    anchor = anchor(record.id)
    :ok = ReceiptOutbox.append(anchor)
    on_exit(fn -> ReceiptOutbox.remove(anchor) end)
    :ok = BrceAnchor.put(anchor)

    assert {:error, {:kernel_fence, :consequence_kernel_required}} =
             Dispatcher.dispatch(:record, message(label), Ledger, [], nil, resolved_skill: record)

    refute label in Fx.ledger_labels()
  end

  defp anchor(capability_id) do
    principal = Identity.principal("rfc004-fence-test")

    command =
      Command.new(capability_id,
        command_id: "rfc004-fence-" <> Ash.UUIDv7.generate(),
        agent_id: "rfc004-fence-agent",
        principal_id: principal,
        authority: Authority.new(principal, capability_id),
        input: %{"label" => "anchor"}
      )

    Receipt.pending(command, Identity.execution(Ash.UUIDv7.generate()), :change)
  end

  defp message(label), do: A2A.Message.new_user([A2A.Part.Data.new(%{"label" => label})])
end
