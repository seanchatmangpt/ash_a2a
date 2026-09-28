defmodule AshA2A.ReceiptStore.StoreHardeningTest do
  @moduledoc """
  Findings R1 (lost actuation commit must not re-open a completed effect),
  R4 (execution-id fencing), and R12/PERF-09 (bounded Memory state) against
  both real backends: a real `AshA2A.ReceiptStore.Memory` GenServer and a
  real on-disk `EKV` (`cluster_size: 1`), with a real filesystem
  `AshA2A.ReceiptOutbox`. Assertions are on the real results the stores
  return; no mocks.

  Leases are injected per call (`claim_lease_ms:` in store opts, TQ-06), so
  nothing here mutates the global `:claim_lease_ms`.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  @moduletag :tmp_dir

  alias AshA2A.{Actuation, Command, Identity, Receipt, ReceiptOutbox}
  alias AshA2A.ReceiptStore.{ActuationClaimLease, Ekv, Memory}

  setup %{tmp_dir: tmp_dir} do
    previous_outbox = Application.get_env(:ash_a2a, :receipt_outbox_dir)
    Application.put_env(:ash_a2a, :receipt_outbox_dir, Path.join(tmp_dir, "outbox"))

    on_exit(fn ->
      case previous_outbox do
        nil -> Application.delete_env(:ash_a2a, :receipt_outbox_dir)
        value -> Application.put_env(:ash_a2a, :receipt_outbox_dir, value)
      end
    end)

    :ok
  end

  defp effect_command(command_id, effect_key) do
    Command.new("AshA2A.Test.Fixture.CountingActuator.actuate",
      command_id: command_id,
      agent_id: "hardening-agent",
      principal_id: "hardening-principal",
      input: %{effect_key: effect_key}
    )
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp memory_opts(extra \\ []) do
    name = :"store_hardening_memory_#{System.unique_integer([:positive])}"
    start_supervised!({Memory, [name: name] ++ extra})
    [name: name]
  end

  defp ekv_opts do
    ekv_name = :"store_hardening_ekv_#{System.unique_integer([:positive])}"

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "ash_a2a_store_hardening_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(data_dir) end)
    start_supervised!({EKV, name: ekv_name, data_dir: data_dir, cluster_size: 1})
    [name: ekv_name]
  end

  # --- R1 ------------------------------------------------------------------

  for backend <- [Memory, Ekv] do
    @backend backend

    describe "R1 #{inspect(backend)}" do
      setup do
        %{opts: if(@backend == Memory, do: memory_opts(), else: ekv_opts())}
      end

      test "a completed effect whose actuation commit was lost answers {:duplicate, primary receipt}, never :proceed",
           %{opts: opts} do
        store = @backend
        key = unique("r1")
        first = effect_command(unique("r1-first"), key)
        actuation = Actuation.identity(first)

        assert {:execute, execution_id} = store.claim(first, opts)
        assert :proceed = store.claim_actuation(actuation, first, opts)

        # DO ran and the PRIMARY receipt committed, but commit_actuation/3
        # was lost (process died / store call failed between the two).
        receipt =
          first
          |> Receipt.pending(execution_id, :external_do)
          |> Receipt.finalize({:reply, 1})

        assert :ok = store.commit(receipt, opts)

        # No anchor remains (commit removed it) and the lease is 0: before
        # R1 this reclaimed the effect and DO ran a second time.
        retry = effect_command(unique("r1-retry"), key)

        assert {:duplicate, %Receipt{replayed?: true} = dup} =
                 store.claim_actuation(actuation, retry, opts ++ [claim_lease_ms: 0])

        assert dup.receipt_id == receipt.receipt_id

        # The entry was healed: a later claimant is answered from the
        # actuation index itself.
        assert {:duplicate, _} =
                 store.claim_actuation(
                   actuation,
                   effect_command(unique("r1-later"), key),
                   opts ++ [claim_lease_ms: 0]
                 )
      end

      test "a claimant whose primary receipt is a pre-DO refusal is reclaimable", %{opts: opts} do
        store = @backend
        key = unique("r1-refused")
        first = effect_command(unique("r1-refused-first"), key)
        actuation = Actuation.identity(first)

        assert {:execute, execution_id} = store.claim(first, opts)
        assert :proceed = store.claim_actuation(actuation, first, opts)

        refusal =
          Receipt.from_reply(
            first,
            execution_id,
            :external_do,
            {:error, %{code: :receipt_anchor_unavailable, detail: "anchor"}}
          )

        assert refusal.terminal_status == :refused
        assert :ok = store.commit(refusal, opts)

        assert :proceed =
                 store.claim_actuation(
                   actuation,
                   effect_command(unique("r1-refused-retry"), key),
                   opts ++ [claim_lease_ms: 0]
                 )
      end

      test "a claimant whose primary receipt is still :pending stays in flight", %{opts: opts} do
        store = @backend
        key = unique("r1-pending")
        first = effect_command(unique("r1-pending-first"), key)
        actuation = Actuation.identity(first)

        assert {:execute, execution_id} = store.claim(first, opts)
        assert :proceed = store.claim_actuation(actuation, first, opts)
        assert :ok = store.commit(Receipt.pending(first, execution_id, :external_do), opts)

        assert {:error, :actuation_in_flight} =
                 store.claim_actuation(
                   actuation,
                   effect_command(unique("r1-pending-retry"), key),
                   opts ++ [claim_lease_ms: 0]
                 )
      end

      # --- R4 --------------------------------------------------------------

      test "commit is fenced on execution id: a reclaimed claim refuses the stale executor",
           %{opts: opts} do
        store = @backend
        command = effect_command(unique("r4"), unique("r4-key"))

        assert {:execute, stale} = store.claim(command, opts)
        # Lease 0 and no anchor: the claim is abandoned and reclaimed.
        assert {:execute, current} = store.claim(command, opts ++ [claim_lease_ms: 0])
        refute stale == current

        assert {:error, :stale_execution} = store.confirm_claim(command.command_id, stale, opts)
        assert :ok = store.confirm_claim(command.command_id, current, opts)

        stale_receipt =
          command |> Receipt.pending(stale, :external_do) |> Receipt.finalize({:reply, :stale})

        current_receipt =
          command
          |> Receipt.pending(current, :external_do)
          |> Receipt.finalize({:reply, :current})

        assert {:error, :stale_execution} = store.commit(stale_receipt, opts)
        assert :ok = store.commit(current_receipt, opts)
        # The stale executor still cannot overwrite after the fact.
        assert {:error, :stale_execution} = store.commit(stale_receipt, opts)

        assert {:ok, %Receipt{reply: {:reply, :current}}} = store.fetch(command.command_id, opts)
      end
    end
  end

  test "ActuationClaimLease.decide/3 never reclaims behind a finalized primary receipt" do
    command = effect_command(unique("decide"), unique("decide-key"))
    execution_id = Identity.execution("decide-exec")

    receipt =
      command |> Receipt.pending(execution_id, :external_do) |> Receipt.finalize({:reply, 1})

    assert {:duplicate, ^receipt} =
             ActuationClaimLease.decide(
               %{receipt: receipt, claimed_at: nil},
               command.command_id,
               claim_lease_ms: 0
             )

    refute ActuationClaimLease.abandoned?(
             %{receipt: receipt, claimed_at: nil},
             command.command_id,
             claim_lease_ms: 0
           )

    assert :reclaim =
             ActuationClaimLease.decide(
               %{receipt: nil, claimed_at: nil},
               command.command_id,
               claim_lease_ms: 0
             )
  end

  # --- R12 / PERF-09 ---------------------------------------------------------

  test "Memory TTL sweep evicts only committed entries older than the TTL" do
    opts = memory_opts(receipt_ttl_ms: 50, sweep_interval_ms: 3_600_000)

    committed = effect_command(unique("ttl-committed"), unique("k"))
    in_flight = effect_command(unique("ttl-inflight"), unique("k"))

    assert {:execute, execution_id} = Memory.claim(committed, opts)
    assert {:execute, _} = Memory.claim(in_flight, opts)

    receipt =
      committed |> Receipt.pending(execution_id, :external_do) |> Receipt.finalize({:reply, 1})

    assert :ok = Memory.commit(receipt, opts)
    assert Memory.size(opts) == 2

    Process.sleep(80)

    assert 1 = Memory.sweep(opts)
    assert Memory.size(opts) == 1
    assert :error = Memory.fetch(committed.command_id, opts)
    # The in-flight claim survives the sweep.
    assert {:error, :in_flight} = Memory.claim(in_flight, opts)
  end

  test "Memory max_entries evicts the oldest committed receipts first, never in-flight claims" do
    opts = memory_opts(max_entries: 2)

    [a, b, c] =
      for label <- ["a", "b", "c"] do
        command = effect_command(unique("max-#{label}"), unique("k"))
        assert {:execute, execution_id} = Memory.claim(command, opts)

        receipt =
          command |> Receipt.pending(execution_id, :external_do) |> Receipt.finalize({:reply, 1})

        assert :ok = Memory.commit(receipt, opts)
        command
      end

    assert Memory.size(opts) == 2
    assert :error = Memory.fetch(a.command_id, opts)
    assert {:ok, _} = Memory.fetch(b.command_id, opts)
    assert {:ok, _} = Memory.fetch(c.command_id, opts)

    # In-flight entries are never evicted, even over the bound.
    for label <- ["x", "y", "z"] do
      assert {:execute, _} =
               Memory.claim(effect_command(unique("inflight-#{label}"), unique("k")), opts)
    end

    assert Memory.size(opts) == 5
  end

  test "Memory TTL sweep keeps a committed primary still referenced by an in-flight actuation entry" do
    opts = memory_opts(receipt_ttl_ms: 20, sweep_interval_ms: 3_600_000)
    key = unique("pinned")
    first = effect_command(unique("pinned-first"), key)
    actuation = Actuation.identity(first)

    assert {:execute, execution_id} = Memory.claim(first, opts)
    assert :proceed = Memory.claim_actuation(actuation, first, opts)

    receipt =
      first |> Receipt.pending(execution_id, :external_do) |> Receipt.finalize({:reply, 1})

    # The primary commit landed; the actuation commit was lost (R1 shape).
    assert :ok = Memory.commit(receipt, opts)
    Process.sleep(40)

    # The expired primary is the only evidence the effect completed: the
    # sweep must keep it, or the effect would be refused forever.
    assert 0 = Memory.sweep(opts)
    assert {:ok, _} = Memory.fetch(first.command_id, opts)

    assert {:duplicate, %Receipt{} = dup} =
             Memory.claim_actuation(
               actuation,
               effect_command(unique("pinned-retry"), key),
               opts ++ [claim_lease_ms: 0]
             )

    assert dup.receipt_id == receipt.receipt_id
  end

  test "Ekv.confirm_claim/3 answers a failed consistent read with a typed refusal, never a raise",
       %{tmp_dir: tmp_dir} do
    # A real EKV member with no CAS config: `EKV.get(_, _, consistent: true)`
    # raises there, exactly as it does on quorum loss.
    name = :"store_hardening_ekv_nocas_#{System.unique_integer([:positive])}"
    start_supervised!({EKV, name: name, data_dir: Path.join(tmp_dir, "ekv-nocas")})
    command = effect_command(unique("nocas"), unique("k"))

    assert {:error, :receipt_store_unavailable} =
             Ekv.confirm_claim(command.command_id, Identity.execution("nocas-exec"), name: name)
  end

  test "a legacy bare-map start still yields a working store (backwards compatible init)" do
    name = :"store_hardening_legacy_#{System.unique_integer([:positive])}"
    {:ok, pid} = GenServer.start(Memory, %{}, name: name)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    command = effect_command(unique("legacy"), unique("k"))
    assert {:execute, _} = Memory.claim(command, name: name)
  end

  test "an outbox entry for one command does not anchor another (R5 scoping at the store)" do
    opts = memory_opts()
    torn_owner = effect_command(unique("torn-owner"), unique("k"))
    other = effect_command(unique("other"), unique("k"))

    File.mkdir_p!(ReceiptOutbox.dir())

    File.write!(
      ReceiptOutbox.entry_path_for(torn_owner.command_id, Identity.runtime("torn")),
      <<131, 104>>
    )

    assert {:execute, _} = Memory.claim(torn_owner, opts)
    assert {:execute, _} = Memory.claim(other, opts)

    # The torn file blocks reclaim of its own command only.
    assert {:error, :in_flight} = Memory.claim(torn_owner, opts ++ [claim_lease_ms: 0])
    assert {:execute, _} = Memory.claim(other, opts ++ [claim_lease_ms: 0])
  end
end
