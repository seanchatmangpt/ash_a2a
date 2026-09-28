defmodule AshA2A.ReceiptStore.BootCheckTest do
  @moduledoc """
  Findings R2 / R12 / PERF-09: `AshA2A.ReceiptStore.boot_check/1` refuses
  configurations whose at-most-once proof would not survive a reboot. All
  inputs are passed as opts, so no application env is mutated; paths are
  real directories (the real tmp dir vs. a real non-tmp directory).
  """

  use ExUnit.Case, async: true

  alias AshA2A.ReceiptStore
  alias AshA2A.ReceiptStore.{Ekv, Memory}

  @durable_dir Path.expand("_build_boot_check_durable", File.cwd!())
  @tmp_dir Path.join(System.tmp_dir!(), "ash_a2a_boot_check")

  defp check(opts) do
    ReceiptStore.boot_check(
      Keyword.merge(
        [
          production: false,
          receipt_store: Memory,
          receipt_outbox_dir: nil,
          receipt_store_ekv_opts: [],
          kill_switch_path: nil,
          allow_memory_receipt_store: false
        ],
        opts
      )
    )
  end

  test "a durable store with a tmp or unset outbox dir is refused" do
    ekv = [data_dir: @durable_dir]

    assert {:error, {:non_durable_outbox_dir, nil}} =
             check(receipt_store: Ekv, receipt_store_ekv_opts: ekv)

    assert {:error, {:non_durable_outbox_dir, @tmp_dir}} =
             check(receipt_store: Ekv, receipt_store_ekv_opts: ekv, receipt_outbox_dir: @tmp_dir)

    assert :ok =
             check(
               receipt_store: Ekv,
               receipt_store_ekv_opts: ekv,
               receipt_outbox_dir: @durable_dir
             )
  end

  test "Ekv with a tmp data_dir is refused" do
    assert {:error, {:non_durable_receipt_store_data_dir, @tmp_dir}} =
             check(
               receipt_store: Ekv,
               receipt_store_ekv_opts: [data_dir: @tmp_dir],
               receipt_outbox_dir: @durable_dir
             )
  end

  test "production refuses an implicit store, the Memory store, a small cluster, and a volatile kill switch" do
    assert {:error, :receipt_store_not_configured} =
             ReceiptStore.boot_check(production: true, receipt_store: nil)

    assert {:error, {:non_durable_receipt_store, Memory}} =
             check(production: true, receipt_store: Memory)

    durable_ekv = [
      production: true,
      receipt_store: Ekv,
      receipt_outbox_dir: @durable_dir,
      receipt_store_ekv_opts: [data_dir: @durable_dir, cluster_size: 1]
    ]

    assert {:error, {:insufficient_cluster_size, 1}} = check(durable_ekv)

    three =
      Keyword.put(durable_ekv, :receipt_store_ekv_opts, data_dir: @durable_dir, cluster_size: 3)

    assert {:error, {:non_durable_kill_switch_path, nil}} = check(three)

    assert :ok = check(Keyword.put(three, :kill_switch_path, Path.join(@durable_dir, "ks.dets")))

    # Escape hatch for Memory is explicit and still needs a durable kill switch.
    assert :ok =
             check(
               production: true,
               receipt_store: Memory,
               allow_memory_receipt_store: true,
               kill_switch_path: Path.join(@durable_dir, "ks.dets")
             )
  end

  test "non-production Memory with defaults stays bootable (backwards compatible)" do
    assert :ok = check([])
  end

  test "durable_path?/1 rejects the tmp dir under any spelling" do
    refute ReceiptStore.durable_path?(nil)
    refute ReceiptStore.durable_path?("")
    refute ReceiptStore.durable_path?(System.tmp_dir!())
    refute ReceiptStore.durable_path?(Path.join(System.tmp_dir!(), "x/y"))
    refute ReceiptStore.durable_path?("/tmp/ash_a2a")
    assert ReceiptStore.durable_path?(@durable_dir)
  end
end
