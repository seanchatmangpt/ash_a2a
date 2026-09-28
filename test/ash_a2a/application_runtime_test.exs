defmodule AshA2A.ApplicationRuntimeTest do
  @moduledoc """
  OBS-07/OBS-08/R7/DEP-10: the application's boot-time runtime report,
  durability enforcement, and default outbox reconciler wiring, exercised
  against the real running application and real `:telemetry`.
  """
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard

  import ExUnit.CaptureLog

  alias AshA2A.Application, as: App

  setup do
    keys = [:outbox_reconciler, :env, :require_durable_receipts]
    previous = for key <- keys, do: {key, Application.get_env(:ash_a2a, key)}

    on_exit(fn ->
      for {key, value} <- previous do
        if is_nil(value),
          do: Application.delete_env(:ash_a2a, key),
          else: Application.put_env(:ash_a2a, key, value)
      end
    end)

    :ok
  end

  test "the outbox reconciler is a default child and can be opted out" do
    Application.delete_env(:ash_a2a, :outbox_reconciler)
    assert App.outbox_reconciler_children() == [{AshA2A.ReceiptOutbox.Reconciler, []}]
    Application.put_env(:ash_a2a, :outbox_reconciler, false)
    assert App.outbox_reconciler_children() == []
  end

  test "the running application started the reconciler unless the host opted out" do
    case Application.get_env(:ash_a2a, :outbox_reconciler, true) do
      false -> assert Process.whereis(AshA2A.ReceiptOutbox.Reconciler) == nil
      _ -> assert is_pid(Process.whereis(AshA2A.ReceiptOutbox.Reconciler))
    end
  end

  test "report_runtime/1 emits [:ash_a2a, :runtime, :configured] and warns once in :prod when non-durable" do
    ref = make_ref()
    parent = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:ash_a2a, :runtime, :configured],
      fn _e, m, md, _ -> send(parent, {ref, m, md}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

    facts = AshA2A.Health.runtime_facts()
    Application.put_env(:ash_a2a, :env, :prod)
    log = capture_log(fn -> assert :ok = App.report_runtime(facts) end)

    assert_receive {^ref, %{system_time: _},
                    %{receipt_store: AshA2A.ReceiptStore.Memory, durable: false}}

    assert log =~ "receipts are not durable"

    Application.put_env(:ash_a2a, :env, :test)
    log = capture_log(fn -> assert :ok = App.report_runtime(facts) end)
    refute log =~ "receipts are not durable"
  end

  test "require_durable_receipts refuses a non-durable runtime and admits a durable one" do
    non_durable = AshA2A.Health.runtime_facts()
    assert :ok = App.enforce_durability(non_durable)

    Application.put_env(:ash_a2a, :require_durable_receipts, true)

    assert {:error, {:non_durable_receipt_store, ^non_durable}} =
             App.enforce_durability(non_durable)

    durable = %{non_durable | durable: true, receipt_outbox_dir_tmp: false}
    assert :ok = App.enforce_durability(durable)

    # Boot path: start/2 refuses before touching the supervisor.
    assert {:error, {:non_durable_receipt_store, _}} = App.start(:normal, [])
  end
end
