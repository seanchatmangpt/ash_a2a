defmodule AshA2A.ReceiptStore.ActuationClaimLeaseTest do
  @moduledoc """
  RFC-SA2A-001 S55 actuation-claim liveness -- RFC-SA2A-002 ARD S40's
  idempotency-store robustness requirement, one index below the primary
  command claim `AshA2A.ReceiptStore.ClaimLease` already covers (qualified by
  `test/ash_a2a/chicago/crash_reconciliation_test.exs`).

  Exercises `AshA2A.ReceiptStore.ActuationClaimLease` through both real
  backends -- a real `AshA2A.ReceiptStore.Memory` GenServer and a real
  on-disk `EKV` instance (`cluster_size: 1`, the same real-local-EKV pattern
  `test/ash_a2a/receipt_store_ekv_test.exs` uses) -- against a real
  filesystem `AshA2A.ReceiptOutbox`. No Mock/mox/patch/monkeypatch anywhere
  in this file: "abandoned" and "reclaimed" are asserted on the real claim
  results the stores return, not on interaction expectations.
  """

  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias AshA2A.{Actuation, Command, Identity, Receipt, ReceiptOutbox}
  alias AshA2A.ReceiptStore.{Ekv, Memory}

  setup %{tmp_dir: tmp_dir} do
    previous_lease = Application.get_env(:ash_a2a, :claim_lease_ms)
    previous_outbox = Application.get_env(:ash_a2a, :receipt_outbox_dir)

    Application.put_env(:ash_a2a, :receipt_outbox_dir, Path.join(tmp_dir, "outbox"))

    on_exit(fn ->
      case previous_lease do
        nil -> Application.delete_env(:ash_a2a, :claim_lease_ms)
        value -> Application.put_env(:ash_a2a, :claim_lease_ms, value)
      end

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
      agent_id: "s55-lease-agent",
      principal_id: "s55-lease-principal",
      input: %{effect_key: effect_key}
    )
  end

  describe "Memory backend" do
    test "an in-flight actuation is reclaimed once its claimant's primary claim is abandoned (lease elapsed, no outbox anchor)" do
      Application.put_env(:ash_a2a, :claim_lease_ms, 20)

      name = :"actuation_lease_memory_#{System.unique_integer([:positive])}"
      start_supervised!({Memory, name: name})
      opts = [name: name]

      key = "actuation-lease-#{System.unique_integer([:positive])}"
      crashed = effect_command("crashed-claimant", key)
      actuation = Actuation.identity(crashed)

      # The crashed claimant's primary command claim...
      assert {:execute, _execution_id} = Memory.claim(crashed, opts)
      # ...and its actuation (effect) claim -- exactly the state a process
      # that died before ever preparing a receipt anchor leaves behind.
      assert :proceed = Memory.claim_actuation(actuation, crashed, opts)

      fresh = effect_command("fresh-claimant", key)

      # Before the lease elapses, a second claimant is refused.
      assert {:error, :actuation_in_flight} = Memory.claim_actuation(actuation, fresh, opts)

      Process.sleep(60)

      # Past the lease, with no outbox anchor for the crashed claimant's
      # command id -- DO could not have started -- a fresh claimant reclaims
      # the effect instead of being refused forever.
      assert :proceed = Memory.claim_actuation(actuation, fresh, opts)

      receipt =
        Receipt.from_reply(
          fresh,
          Identity.execution("lease-memory-exec"),
          :external_do,
          {:reply, []}
        )

      assert :ok = Memory.commit_actuation(actuation, receipt, opts)

      later = effect_command("later-claimant", key)

      assert {:duplicate, %Receipt{replayed?: true}} =
               Memory.claim_actuation(actuation, later, opts)
    end

    test "an in-flight actuation is never reclaimed once its claimant's primary claim reached the outbox anchor, no matter how long the lease has passed" do
      Application.put_env(:ash_a2a, :claim_lease_ms, 20)

      name = :"actuation_lease_anchored_memory_#{System.unique_integer([:positive])}"
      start_supervised!({Memory, name: name})
      opts = [name: name]

      key = "actuation-anchored-#{System.unique_integer([:positive])}"
      claimant = effect_command("anchored-claimant", key)
      actuation = Actuation.identity(claimant)

      assert {:execute, execution_id} = Memory.claim(claimant, opts)
      assert :proceed = Memory.claim_actuation(actuation, claimant, opts)

      # The claimant reached the pre-DO receipt boundary before "crashing" --
      # DO may already have run.
      anchor = Receipt.pending(claimant, execution_id, :external_do)
      :ok = ReceiptOutbox.append(anchor)

      Process.sleep(60)

      fresh = effect_command("fresh-claimant-anchored", key)

      # Well past the lease, but the anchor exists: this effect may already
      # have actuated, so the actuation claim must stay in-flight -- the
      # lease alone never reclaims it.
      assert {:error, :actuation_in_flight} = Memory.claim_actuation(actuation, fresh, opts)
    end
  end

  describe "Ekv backend" do
    setup do
      ekv_name = :"actuation_lease_ekv_#{System.unique_integer([:positive])}"

      data_dir =
        Path.join(
          System.tmp_dir!(),
          "ash_a2a_actuation_claim_lease_test_#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> File.rm_rf!(data_dir) end)

      # cluster_size: 1 -- a real single-voter setup, the same real-local-EKV
      # pattern test/ash_a2a/receipt_store_ekv_test.exs already uses.
      start_supervised!({EKV, name: ekv_name, data_dir: data_dir, cluster_size: 1})

      %{store_opts: [name: ekv_name]}
    end

    test "an in-flight actuation is reclaimed once its claimant's primary claim is abandoned", %{
      store_opts: store_opts
    } do
      Application.put_env(:ash_a2a, :claim_lease_ms, 20)

      key = "actuation-lease-ekv-#{System.unique_integer([:positive])}"
      crashed = effect_command("crashed-claimant-ekv", key)
      actuation = Actuation.identity(crashed)

      assert {:execute, _execution_id} = Ekv.claim(crashed, store_opts)
      assert :proceed = Ekv.claim_actuation(actuation, crashed, store_opts)

      fresh = effect_command("fresh-claimant-ekv", key)
      assert {:error, :actuation_in_flight} = Ekv.claim_actuation(actuation, fresh, store_opts)

      Process.sleep(60)

      assert :proceed = Ekv.claim_actuation(actuation, fresh, store_opts)

      receipt =
        Receipt.from_reply(
          fresh,
          Identity.execution("lease-ekv-exec"),
          :external_do,
          {:reply, []}
        )

      assert :ok = Ekv.commit_actuation(actuation, receipt, store_opts)

      later = effect_command("later-claimant-ekv", key)

      assert {:duplicate, %Receipt{replayed?: true}} =
               Ekv.claim_actuation(actuation, later, store_opts)
    end

    test "an in-flight actuation is never reclaimed once its claimant's primary claim reached the outbox anchor",
         %{store_opts: store_opts} do
      Application.put_env(:ash_a2a, :claim_lease_ms, 20)

      key = "actuation-anchored-ekv-#{System.unique_integer([:positive])}"
      claimant = effect_command("anchored-claimant-ekv", key)
      actuation = Actuation.identity(claimant)

      assert {:execute, execution_id} = Ekv.claim(claimant, store_opts)
      assert :proceed = Ekv.claim_actuation(actuation, claimant, store_opts)

      anchor = Receipt.pending(claimant, execution_id, :external_do)
      :ok = ReceiptOutbox.append(anchor)

      Process.sleep(60)

      fresh = effect_command("fresh-claimant-ekv-anchored", key)
      assert {:error, :actuation_in_flight} = Ekv.claim_actuation(actuation, fresh, store_opts)
    end
  end
end
