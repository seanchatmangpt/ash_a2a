defmodule AshA2A.Reconciliation.MapeKTest do
  @moduledoc """
  Real MAPE-K loop over a real `AshA2A.ReceiptStore.Memory` and a real
  filesystem outbox. Asserts final durable state and the Knowledge map; no
  mocks. The probe is a plain function reading a real Agent-held external
  ledger (a real collaborator, not an interaction verifier).
  """
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias AshA2A.{Command, Receipt, ReceiptOutbox, Reconciliation}
  alias AshA2A.Reconciliation.MapeK
  alias AshA2A.ReceiptStore.Memory

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:ash_a2a, :receipt_outbox_dir)
    Application.put_env(:ash_a2a, :receipt_outbox_dir, Path.join(dir, "outbox"))
    on_exit(fn -> Application.put_env(:ash_a2a, :receipt_outbox_dir, previous) end)
    name = :"mapek_store_#{System.unique_integer([:positive])}"
    start_supervised!({Memory, name: name})
    %{opts: [name: name]}
  end

  defp anchor(opts) do
    command =
      Command.new("AshA2A.Chicago.Fixtures.ChaosReconciliation.Effect.apply_effect",
        command_id: "mapek-#{System.unique_integer([:positive])}",
        agent_id: "a",
        principal_id: "p",
        input: %{}
      )

    {:execute, execution_id} = Memory.claim(command, opts)
    receipt = Receipt.pending(command, execution_id, :external_do)
    :ok = ReceiptOutbox.append(receipt)
    {command.command_id, receipt}
  end

  test "loop resolves pending anchors via the probe and records Knowledge", %{opts: opts} do
    {id1, r1} = anchor(opts)
    {id2, _r2} = anchor(opts)
    unseen = AshA2A.Identity.command("mapek-unseen-#{System.unique_integer([:positive])}")

    {:ok, ledger} = Agent.start_link(fn -> MapSet.new([r1.receipt_id]) end)

    probe = fn receipt ->
      if Agent.get(ledger, &MapSet.member?(&1, receipt.receipt_id)),
        do: {:executed, %{"seen" => true}},
        else: {:not_executed, %{"seen" => false}}
    end

    assert {:ok, k} = MapeK.run([id1, id2, unseen], Memory, opts, probe: probe)

    assert %{state: :reconciled, settled?: true} = k[id1.value]
    assert %{state: :reconciled, settled?: true} = k[id2.value]
    assert %{state: :not_attempted, settled?: true, plans: []} = k[unseen.value]
    assert [:reconcile] = k[id1.value].plans

    # Final durable state, independently read.
    assert {:ok, %{state: :reconciled, resolved_as: :executed}} =
             Reconciliation.classify(id1, Memory, opts)

    assert {:ok, %{state: :reconciled, resolved_as: :not_executed}} =
             Reconciliation.classify(id2, Memory, opts)
  end

  test "without a probe the loop defers and never infers an outcome", %{opts: opts} do
    {id, _} = anchor(opts)
    assert {:ok, k} = MapeK.run([id], Memory, opts, max_iterations: 2)
    assert %{state: :prepared_unknown_outcome, settled?: false} = k[id.value]

    assert {:ok, %{state: :prepared_unknown_outcome}} =
             Reconciliation.classify(id, Memory, opts)
  end
end
