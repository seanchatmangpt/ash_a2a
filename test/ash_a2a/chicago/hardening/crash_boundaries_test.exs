defmodule AshA2A.Chicago.Hardening.CrashBoundariesTest do
  @moduledoc """
  RFC-SA2A-002 §70 crash-boundary hardening: a direct, standalone regression
  guard for the five named crash points, distinct in purpose from
  `test/ash_a2a/chicago/crash_reconciliation_test.exs` (which qualifies the
  `SA2A-CHAOS` Falsifier court through `AshA2A.Chicago.Runner` and its OCEL
  corroboration layer). This file asserts directly on the real durable state
  the production modules produce, with no Falsifier/Runner/OCEL machinery in
  the path, so a regression here is caught even if a bug were hiding inside
  that scoring layer itself.

  Every test drives the real `AshA2A.CommandBus.run/4` (via the real,
  already-established `AshA2A.Chicago.Fixtures.ChaosReconciliation.Environment`
  fault-injection fixture -- reused here verbatim, never reinvented) against
  a real on-disk `AshA2A.ReceiptStore.Ekv`, a real filesystem
  `AshA2A.ReceiptOutbox`, and a real Ash ETS external ledger
  (`AshA2A.Chicago.Fixtures.ChaosReconciliation.Effect`). Every crash is a
  real, untrappable `Process.exit(pid, :kill)` on a real spawned process
  running the SUT mid-flight (`Environment.run_crashing/4`), matching the
  established real-process-kill pattern already used by
  `test/ash_a2a_failure_injection_test.exs` (`Process.flag(:trap_exit,
  true)` + a genuine `exit/1`, not a raised-and-rescued exception, not a
  stubbed collaborator). Nothing on the path is replaced by a double.

  Each test names its crash point in RFC-SA2A-002 §70's own vocabulary and
  asserts the exact `AshA2A.Reconciliation` state the surviving durable
  evidence must classify to -- never a generic "did not crash" check --
  plus the real, independently-read external-ledger row count, so a
  regression that silently double-actuates or silently drops the crash
  point's own distinguishing evidence fails a concrete assertion here
  instead of passing quietly.

  `async: false`: `Environment.open/1` mutates the global
  `:receipt_outbox_dir` application env for its lifetime.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.{Identity, Receipt, Reconciliation}
  alias AshA2A.Chicago.Fixtures.ChaosReconciliation.Environment, as: Env

  @moduletag :tmp_dir
  @moduletag capture_log: true
  @moduletag timeout: 120_000

  @claim [:ash_a2a, :command_bus, :claim]
  @prepare [:ash_a2a, :command_bus, :prepare]
  @actuate_stop [:ash_a2a, :command_bus, :actuate, :stop]
  @commit [:ash_a2a, :command_bus, :commit]

  # Long enough that the external call is reliably still "in progress" (the
  # spawned SUT process has not yet returned) at the instant
  # `Environment.run_crashing/4`'s polling loop observes the freshly-applied
  # row and kills it -- short enough to keep the suite fast.
  @stall_ms 5_000

  setup_all do
    # The crash-injection technique below relies on `:telemetry` dispatching
    # the already-attached crash handler synchronously, inside the emitting
    # SUT process, at the real CommandBus boundary event -- i.e. on ordered
    # dispatch. Verified for real on the live node (not assumed) before any
    # crash is injected, the same precondition
    # `AshA2A.Chicago.Courts.CrashReconciliation` itself checks.
    assert Env.attach_ordered?(),
           "telemetry does not dispatch handlers in attach order on this node; " <>
             "a boundary crash handler could race the SUT's own evidence write"

    :ok
  end

  setup %{tmp_dir: dir} do
    env = Env.open(dir)
    on_exit(fn -> Env.close(env) end)
    %{env: env}
  end

  describe "crash point 1: before receipt preparation" do
    test "no consequence, classified not_attempted; an immediate resubmission stays refused in_flight (never a silent guess), and once the real claim lease elapses it actuates exactly once",
         %{env: env} do
      cid = command_id("crash1")
      input = input(cid)

      crash = Env.run_crashing(env, cid, input, {:at_event, @claim, %{outcome: :execute}})
      assert crash.crash_point_reached?, "crash point never reached: #{inspect(crash)}"

      # No BRCE anchor was ever durably prepared, so no consequence can have
      # begun -- the real external ledger must show zero rows.
      assert Env.rows(cid) == 0

      env = Env.restart_store(env)

      assert {:ok, %{state: :not_attempted}} = classify(env, cid)

      # `AshA2A.ReceiptStore.ClaimLease` never reclaims an in-flight claim
      # immediately (default lease: 300_000ms) -- the crashed executor might
      # still be alive and about to actuate, so an immediate resubmission
      # must stay refused `in_flight` rather than risk a second real
      # actuation. This is the real safety half of the liveness/safety
      # tradeoff `AshA2A.ReceiptStore.ClaimLease` documents; asserted here
      # against the real default configuration (no override).
      assert {:error, %{code: :in_flight}} = Env.run(env, cid, input)
      assert Env.rows(cid) == 0

      # With a short lease configured (the real, established pattern this
      # module already uses for exactly this crash point -- reused here, not
      # reinvented), once the lease genuinely elapses the abandoned claim
      # becomes reclaimable and the resubmission actuates for real, exactly
      # once.
      lease_ms = 50

      with_claim_lease(lease_ms, fn ->
        cid2 = command_id("crash1-lease")
        input2 = input(cid2)

        crash2 = Env.run_crashing(env, cid2, input2, {:at_event, @claim, %{outcome: :execute}})
        assert crash2.crash_point_reached?, "crash point never reached: #{inspect(crash2)}"

        Process.sleep(lease_ms * 3)

        resubmission = Env.run(env, cid2, input2)

        assert match?({:ok, %Receipt{status: :completed, replayed?: false}}, resubmission),
               "expected a fresh, non-replayed actuation once the lease elapsed, " <>
                 "got: #{inspect(resubmission)}"

        assert Env.rows(cid2) == 1

        replay = Env.run(env, cid2, input2)
        assert match?({:ok, %Receipt{replayed?: true}}, replay)
        assert Env.rows(cid2) == 1, "the reclaimed actuation must never repeat on replay"
      end)
    end
  end

  describe "crash point 2: after receipt preparation / before the external call" do
    test "prepared_unknown_outcome, reconciles not_executed, and resubmission replays without ever actuating",
         %{env: env} do
      cid = command_id("crash2")
      input = input(cid)

      crash = Env.run_crashing(env, cid, input, {:at_event, @prepare, %{outcome: :prepared}})
      assert crash.crash_point_reached?, "crash point never reached: #{inspect(crash)}"

      # The anchor was written before the external call, so the call itself
      # never ran -- the real external ledger must show zero rows.
      assert Env.rows(cid) == 0

      env = Env.restart_store(env)

      assert {:ok, %{state: :prepared_unknown_outcome}} = classify(env, cid)

      assert {:ok, %{after: after_c}} = reconcile(env, cid, probe: &Env.probe/1)
      assert %{state: :reconciled, resolved_as: :not_executed} = after_c

      resubmission = Env.run(env, cid, input)

      assert match?({:ok, %Receipt{replayed?: true}}, resubmission),
             "the invariant is 'never actuated on resubmission' -- a fresh actuation here " <>
               "would mean the caller's retry silently re-runs a call whose prior in-flight " <>
               "outcome was never known, got: #{inspect(resubmission)}"

      assert Env.rows(cid) == 0
    end
  end

  describe "crash point 3: during the external call" do
    test "the real effect is already applied, classifies prepared_unknown_outcome, reconciles executed, and resubmission never repeats the effect",
         %{env: env} do
      cid = command_id("crash3")
      input = Map.put(input(cid), "hang_after_ms", @stall_ms)

      crash = Env.run_crashing(env, cid, input, :during_external_call)
      assert crash.crash_point_reached?, "crash point never reached: #{inspect(crash)}"

      # The distinguishing fact of this crash point versus crash point 2:
      # the real external effect already happened before the kill.
      assert Env.rows(cid) == 1

      env = Env.restart_store(env)

      assert {:ok, %{state: :prepared_unknown_outcome}} = classify(env, cid)

      assert {:ok, %{after: after_c}} = reconcile(env, cid, probe: &Env.probe/1)
      assert %{state: :reconciled, resolved_as: :executed} = after_c

      resubmission = Env.run(env, cid, input)

      assert match?({:ok, %Receipt{replayed?: true}}, resubmission),
             "a real effect already happened -- resubmission must replay, never re-actuate, " <>
               "got: #{inspect(resubmission)}"

      assert Env.rows(cid) == 1, "the external effect must never be repeated"
    end
  end

  describe "crash point 4: after the external response / before finalization" do
    test "the real effect is already applied, classifies prepared_unknown_outcome, reconciles executed, and resubmission never repeats the effect",
         %{env: env} do
      cid = command_id("crash4")
      input = input(cid)

      crash = Env.run_crashing(env, cid, input, {:at_event, @actuate_stop, %{}})
      assert crash.crash_point_reached?, "crash point never reached: #{inspect(crash)}"

      # The actuator already returned success before the kill -- distinct
      # code path from crash point 3 (killed mid-call, no return observed
      # at all), same real external consequence already durable.
      assert Env.rows(cid) == 1

      env = Env.restart_store(env)

      assert {:ok, %{state: :prepared_unknown_outcome}} = classify(env, cid)

      assert {:ok, %{after: after_c}} = reconcile(env, cid, probe: &Env.probe/1)
      assert %{state: :reconciled, resolved_as: :executed} = after_c

      resubmission = Env.run(env, cid, input)

      assert match?({:ok, %Receipt{replayed?: true}}, resubmission),
             "a real effect already happened -- resubmission must replay, never re-actuate, " <>
               "got: #{inspect(resubmission)}"

      assert Env.rows(cid) == 1, "the external effect must never be repeated"
    end
  end

  describe "crash point 5: after finalization / before caller acknowledgement" do
    test "classifies executed directly (no reconciliation pass required) and the caller's retry only ever replays",
         %{env: env} do
      cid = command_id("crash5")
      input = input(cid)

      crash = Env.run_crashing(env, cid, input, {:at_event, @commit, %{outcome: :committed}})
      assert crash.crash_point_reached?, "crash point never reached: #{inspect(crash)}"

      # The receipt was already durably committed before the kill -- only
      # the reply to the caller was lost. The real external effect ran once.
      assert Env.rows(cid) == 1

      env = Env.restart_store(env)

      # The key distinguishing property of this crash point: the durable
      # evidence alone already resolves to :executed with no reconciliation
      # probe needed at all (unlike crash points 2-4, whose classification
      # stays prepared_unknown_outcome until a reconcile/4 pass runs).
      assert {:ok, %{state: :executed}} = classify(env, cid)

      resubmission = Env.run(env, cid, input)

      assert match?({:ok, %Receipt{status: :completed, replayed?: true}}, resubmission),
             "the caller's retry must replay the already-committed receipt, never re-actuate, " <>
               "got: #{inspect(resubmission)}"

      assert Env.rows(cid) == 1, "the external effect must never be repeated"
    end
  end

  # --- helpers -----------------------------------------------------------------

  defp command_id(prefix),
    do: prefix <> "-" <> Integer.to_string(System.unique_integer([:positive]))

  defp input(cid), do: %{"operation_id" => cid}

  defp classify(env, cid),
    do: Reconciliation.classify(Identity.command(cid), Env.store(), Env.store_opts(env))

  defp reconcile(env, cid, opts),
    do: Reconciliation.reconcile(Identity.command(cid), Env.store(), Env.store_opts(env), opts)

  # Scopes a short `:claim_lease_ms` to `fun`, always restoring whatever was
  # configured before -- the same real pattern
  # `AshA2A.Chicago.Courts.CrashReconciliation`'s own scenario 19/20 already
  # establish for this exact crash point, reused here rather than reinvented.
  defp with_claim_lease(lease_ms, fun) do
    previous = Application.get_env(:ash_a2a, :claim_lease_ms)
    Application.put_env(:ash_a2a, :claim_lease_ms, lease_ms)

    try do
      fun.()
    after
      case previous do
        nil -> Application.delete_env(:ash_a2a, :claim_lease_ms)
        value -> Application.put_env(:ash_a2a, :claim_lease_ms, value)
      end
    end
  end
end
