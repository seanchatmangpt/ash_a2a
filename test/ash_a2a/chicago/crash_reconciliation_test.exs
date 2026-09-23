defmodule AshA2A.Chicago.CrashReconciliationTest do
  @moduledoc """
  Qualifies the `SA2A-CHAOS` court (RFC-SA2A-002 §70, §71, §94, §96) and the
  modules it introduces, Chicago style: real `AshA2A.CommandBus`, real
  on-disk EKV receipt store killed and restarted, real filesystem receipt
  outbox, real Ash ETS external ledger, real `AshA2A.ReceiptStore.Memory`,
  real telemetry, and a durable OCEL artifact read back by the independent
  consumer. No component on the path is replaced by a double.

  `async: false` -- the observer attributes every telemetry event emitted
  between a stimulus start and stop to that falsifier, and these tests point
  the global `:receipt_outbox_dir` at private directories.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.{Command, CommandBus, Identity, Receipt, ReceiptOutbox, Reconciliation}
  alias AshA2A.Chicago.Courts.CrashReconciliation
  alias AshA2A.Chicago.Fixtures.ChaosReconciliation.Environment, as: Env
  alias AshA2A.Chicago.Runner
  alias AshA2A.ReceiptStore.Memory

  @moduletag :tmp_dir
  @moduletag capture_log: true
  @moduletag timeout: 600_000

  @expected %{
    "SA2A-CHAOS-001" => :falsifier_killed,
    "SA2A-CHAOS-002" => :falsifier_killed,
    "SA2A-CHAOS-003" => :falsifier_killed,
    "SA2A-CHAOS-004" => :falsifier_killed,
    "SA2A-CHAOS-005" => :falsifier_killed,
    "SA2A-CHAOS-006" => :falsifier_killed,
    "SA2A-CHAOS-007" => :falsifier_killed,
    "SA2A-CHAOS-008" => :falsifier_killed,
    "SA2A-CHAOS-009" => :falsifier_killed,
    "SA2A-CHAOS-010" => :falsifier_killed,
    "SA2A-CHAOS-011" => :falsifier_killed,
    "SA2A-CHAOS-012" => :falsifier_killed,
    "SA2A-CHAOS-013" => :falsifier_killed,
    "SA2A-CHAOS-014" => :positive_control_passed,
    "SA2A-CHAOS-015" => :positive_control_passed,
    "SA2A-CHAOS-016" => :positive_control_passed,
    "SA2A-CHAOS-017" => :positive_control_passed,
    "SA2A-CHAOS-018" => :measured,
    "SA2A-CHAOS-019" => :falsifier_killed,
    "SA2A-CHAOS-020" => :falsifier_killed
  }

  describe "the SA2A-CHAOS court over the real SUT" do
    test "every falsifier reaches its verdict and every pass is corroborated by the independent OCEL consumer",
         %{tmp_dir: dir} do
      assert {:ok, run} =
               Runner.run(courts: [CrashReconciliation], profile: :do, evidence_dir: dir)

      by_id = Map.new(run.results, &{&1.falsifier_id, &1})
      assert Map.keys(by_id) |> Enum.sort() == Map.keys(@expected) |> Enum.sort()

      for {id, verdict} <- @expected do
        result = by_id[id]

        assert result.verdict == verdict,
               "#{id}: expected #{verdict}, got #{result.verdict} -- " <>
                 "#{inspect(result.detail)} / #{inspect(result.ocel_detail)}"

        assert result.ocel_corroborated? == true, "#{id}: #{inspect(result.ocel_detail)}"
      end

      assert run.ocel.dropped == 0

      receipt = JSON.decode!(File.read!(Path.join(dir, "standing_receipt.json")))
      assert receipt["results"]["falsifiers_killed"] == 15
      assert receipt["results"]["falsifiers_survived"] == 0
      assert receipt["results"]["positive_controls_passed"] == 4
      assert receipt["results"]["measured"] == 1
      assert receipt["results"]["unresolved_ids"] == []

      # SA2A-B10: every crash point reached, zero repeated external effects,
      # the six-state vocabulary actually exercised.
      b10 = by_id["SA2A-CHAOS-018"].measurements
      assert b10["crash_points_reached"] == 5
      assert b10["repeated_external_effects_total"] == 0

      assert Enum.map(b10["points"], & &1["prepared_receipt_state"]["classification"]) == [
               :not_attempted,
               :prepared_unknown_outcome,
               :prepared_unknown_outcome,
               :prepared_unknown_outcome,
               :executed
             ]

      assert Enum.map(b10["points"], & &1["reconciliation_result"]["resolved_as"]) == [
               nil,
               :not_executed,
               :executed,
               :executed,
               nil
             ]
    end
  end

  describe "AshA2A.Reconciliation over a real Memory store and a real outbox" do
    setup %{tmp_dir: dir} do
      previous = Application.get_env(:ash_a2a, :receipt_outbox_dir)
      outbox = Path.join(dir, "outbox")
      Application.put_env(:ash_a2a, :receipt_outbox_dir, outbox)
      on_exit(fn -> Application.put_env(:ash_a2a, :receipt_outbox_dir, previous) end)

      name = :"reconciliation_test_store_#{System.unique_integer([:positive])}"
      start_supervised!({Memory, name: name})
      %{store_opts: [name: name], outbox: outbox}
    end

    test "no evidence is not_attempted; an unreadable journal entry forbids it", %{
      store_opts: opts,
      outbox: outbox
    } do
      cid = Identity.command("never-#{System.unique_integer([:positive])}")

      assert {:ok, %{state: :not_attempted, source: :none}} =
               Reconciliation.classify(cid, Memory, opts)

      File.mkdir_p!(outbox)
      File.write!(Path.join(outbox, "runtime:torn.receipt"), <<131, 104>>)

      assert {:ok, %{state: :prepared_unknown_outcome, unreadable_outbox_entries: 1}} =
               Reconciliation.classify(cid, Memory, opts)
    end

    test "a pending anchor is prepared_unknown_outcome and a probe resolves it; :unknown leaves it",
         %{store_opts: opts} do
      {command, anchor} = claimed_anchor(opts)
      :ok = ReceiptOutbox.append(anchor)

      assert {:ok, %{state: :prepared_unknown_outcome, source: :outbox}} =
               Reconciliation.classify(command.command_id, Memory, opts)

      assert {:ok, %{outcome: :unresolved, after: %{state: :prepared_unknown_outcome}}} =
               Reconciliation.reconcile(command.command_id, Memory, opts,
                 probe: fn _ -> :unknown end
               )

      assert {:ok, %{outcome: :resolved, after: after_c}} =
               Reconciliation.reconcile(command.command_id, Memory, opts,
                 probe: fn _ -> {:executed, %{"seen" => 1}} end
               )

      assert %{state: :reconciled, resolved_as: :executed, source: :primary} = after_c
      assert after_c.receipt.receipt_id == anchor.receipt_id

      # Reconciliation is idempotent: a reconciled receipt is never re-resolved.
      assert {:ok, %{outcome: :unchanged, after: %{state: :reconciled}}} =
               Reconciliation.reconcile(command.command_id, Memory, opts,
                 probe: fn _ -> {:not_executed, %{}} end
               )
    end

    test "a finalized outboxed receipt outranks the pending anchor already in the primary store",
         %{store_opts: opts} do
      {command, anchor} = claimed_anchor(opts)
      :ok = Memory.commit(anchor, opts)
      finalized = Receipt.finalize(anchor, {:reply, []})
      :ok = ReceiptOutbox.append(finalized)

      assert {:ok, %{state: :executed, source: :outbox, durable_in_primary?: false}} =
               Reconciliation.classify(command.command_id, Memory, opts)
    end

    test "an unavailable primary store is an error, never a guessed state", %{store_opts: opts} do
      {command, _anchor} = claimed_anchor(opts)
      stop_supervised!(Memory)

      assert {:error, :receipt_store_unavailable} =
               Reconciliation.classify(command.command_id, Memory, opts)
    end

    test "only an executed consequence can be compensated", %{store_opts: opts} do
      {command, anchor} = claimed_anchor(opts)
      :ok = Memory.commit(anchor, opts)

      assert {:error, %{code: :compensation_not_applicable}} =
               Reconciliation.compensate(command.command_id, Memory, opts, fn _ ->
                 send(self(), :compensation_ran)
                 {:error, %{code: :must_not_run}}
               end)

      refute_received :compensation_ran

      :ok = Memory.commit(Receipt.finalize(anchor, {:reply, []}), opts)

      assert {:error, %{code: :compensation_unconfirmed}} =
               Reconciliation.compensate(command.command_id, Memory, opts, fn _ ->
                 {:error, %{code: :dispatch_crashed}}
               end)

      assert {:ok, %{state: :executed}} =
               Reconciliation.classify(command.command_id, Memory, opts)

      assert AshA2A.Chicago.refusal_codes()[:compensation_not_applicable] == :refused_consequence
    end
  end

  describe "ReceiptOutbox.reconcile finalized-supersedes-pending guard (SA2A-CHAOS-012 repair)" do
    setup %{tmp_dir: dir} do
      previous = Application.get_env(:ash_a2a, :receipt_outbox_dir)
      Application.put_env(:ash_a2a, :receipt_outbox_dir, Path.join(dir, "outbox"))
      on_exit(fn -> Application.put_env(:ash_a2a, :receipt_outbox_dir, previous) end)

      name = :"supersede_test_store_#{System.unique_integer([:positive])}"
      start_supervised!({Memory, name: name})
      %{store_opts: [name: name]}
    end

    test "a finalized entry replaces its own drained pending anchor", %{store_opts: opts} do
      {command, anchor} = claimed_anchor(opts)
      :ok = Memory.commit(anchor, opts)
      :ok = ReceiptOutbox.append(Receipt.finalize(anchor, {:reply, []}))

      assert {:ok, %{committed: 1, remaining: 0}} =
               CommandBus.reconcile_outboxed_receipts(Memory, opts)

      assert {:ok, %Receipt{status: :completed}} = Memory.fetch(command.command_id, opts)
      assert ReceiptOutbox.count() == 0
    end

    test "a stale pending entry never downgrades a finalized stored receipt", %{store_opts: opts} do
      {command, anchor} = claimed_anchor(opts)
      :ok = Memory.commit(Receipt.finalize(anchor, {:reply, []}), opts)
      :ok = ReceiptOutbox.append(anchor)

      assert {:ok, %{committed: 0, remaining: 0}} =
               CommandBus.reconcile_outboxed_receipts(Memory, opts)

      assert {:ok, %Receipt{status: :completed}} = Memory.fetch(command.command_id, opts)
    end
  end

  describe "fault-injection environment" do
    test "telemetry dispatches in attach order and an EKV crash/restart keeps what reached disk",
         %{tmp_dir: dir} do
      assert Env.attach_ordered?()

      env = Env.open(dir)

      try do
        opts = Env.store_opts(env)
        command = Env.command("env-restart-#{System.unique_integer([:positive])}", %{})
        assert {:execute, _} = Env.store().claim(command, opts)

        Env.crash_store(env)
        refute Env.store_alive?(env)
        assert %{primary: :unavailable} = Env.raw_evidence(env, command.command_id.value)

        Env.restart_store(env)
        assert Env.store_alive?(env)
        assert %{primary: :claimed} = Env.raw_evidence(env, command.command_id.value)
        assert {:error, :in_flight} = Env.store().claim(command, opts)
      after
        Env.close(env)
      end
    end
  end

  describe "ReceiptStore.Memory claim lease reclaim (closes the SA2A-CHAOS liveness gap)" do
    setup do
      previous = Application.get_env(:ash_a2a, :claim_lease_ms)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:ash_a2a, :claim_lease_ms)
          value -> Application.put_env(:ash_a2a, :claim_lease_ms, value)
        end
      end)

      :ok
    end

    test "an abandoned claim (no outbox anchor) is reclaimable once the lease elapses" do
      Application.put_env(:ash_a2a, :claim_lease_ms, 20)
      name = :"claim_lease_memory_#{System.unique_integer([:positive])}"
      start_supervised!({Memory, name: name})
      opts = [name: name]
      command = unit_command("lease-memory")

      assert {:execute, first_execution_id} = Memory.claim(command, opts)
      assert {:error, :in_flight} = Memory.claim(command, opts)

      Process.sleep(60)

      assert {:execute, second_execution_id} = Memory.claim(command, opts)
      assert second_execution_id != first_execution_id

      # The reclaimed execution commits normally, and the command id then
      # replays -- reclaim behaves exactly like a fresh claim from here on.
      receipt = Receipt.from_reply(command, second_execution_id, :external_do, {:reply, []}, [])
      :ok = Memory.commit(receipt, opts)
      assert {:replay, %Receipt{replayed?: true}} = Memory.claim(command, opts)
    end

    test "a claim that reached receipt preparation is never reclaimed, no matter how long the lease has passed",
         %{tmp_dir: dir} do
      Application.put_env(:ash_a2a, :claim_lease_ms, 20)
      previous_outbox = Application.get_env(:ash_a2a, :receipt_outbox_dir)
      Application.put_env(:ash_a2a, :receipt_outbox_dir, Path.join(dir, "lease_anchor_outbox"))

      on_exit(fn ->
        case previous_outbox do
          nil -> Application.delete_env(:ash_a2a, :receipt_outbox_dir)
          value -> Application.put_env(:ash_a2a, :receipt_outbox_dir, value)
        end
      end)

      name = :"claim_lease_anchored_memory_#{System.unique_integer([:positive])}"
      start_supervised!({Memory, name: name})
      opts = [name: name]
      command = unit_command("lease-anchored")

      assert {:execute, execution_id} = Memory.claim(command, opts)
      anchor = Receipt.pending(command, execution_id, :external_do)
      :ok = ReceiptOutbox.append(anchor)

      Process.sleep(60)

      # Well past the lease, but a pending anchor exists: this claim may
      # already have actuated, so it must stay in_flight -- the lease alone
      # never reclaims it.
      assert {:error, :in_flight} = Memory.claim(command, opts)
    end
  end

  defp unit_command(prefix) do
    Command.new("AshA2A.Chicago.Fixtures.ChaosReconciliation.Effect.apply_effect",
      command_id: "#{prefix}-#{System.unique_integer([:positive])}",
      agent_id: "unit-agent",
      principal_id: "unit-principal",
      input: %{}
    )
  end

  defp claimed_anchor(opts) do
    command =
      Command.new("AshA2A.Chicago.Fixtures.ChaosReconciliation.Effect.apply_effect",
        command_id: "reconciliation-unit-#{System.unique_integer([:positive])}",
        agent_id: "unit-agent",
        principal_id: "unit-principal",
        input: %{}
      )

    {:execute, execution_id} = Memory.claim(command, opts)
    {command, Receipt.pending(command, execution_id, :external_do)}
  end
end
