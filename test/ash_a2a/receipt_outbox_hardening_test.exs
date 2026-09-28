defmodule AshA2A.ReceiptOutboxHardeningTest do
  @moduledoc """
  Findings R5 (command-keyed anchors), TQ-04 (`:safe` decoding of journal
  bytes), OBS-09 (corrupt entries raise a standing signal), and the R4
  re-claim rebinding, against a real filesystem `AshA2A.ReceiptOutbox` in a
  per-test tmp dir, a real `AshA2A.ReceiptStore.Memory`, and a real
  `AshA2A.ReceiptOutbox.Reconciler` GenServer. No mocks.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  @moduletag :tmp_dir

  alias AshA2A.{Command, Identity, Receipt, ReceiptOutbox}
  alias AshA2A.Receipt.{Binding, EvidenceChain}
  alias AshA2A.ReceiptOutbox.Reconciler
  alias AshA2A.ReceiptStore.Memory

  setup %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:ash_a2a, :receipt_outbox_dir)
    dir = Path.join(tmp_dir, "outbox")
    Application.put_env(:ash_a2a, :receipt_outbox_dir, dir)
    File.mkdir_p!(dir)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:ash_a2a, :receipt_outbox_dir)
        value -> Application.put_env(:ash_a2a, :receipt_outbox_dir, value)
      end
    end)

    %{dir: dir}
  end

  defp command(label) do
    Command.new("AshA2A.Test.Fixture.CountingActuator.actuate",
      command_id: "#{label}-#{System.unique_integer([:positive])}",
      agent_id: "outbox-hardening-agent",
      principal_id: "outbox-hardening-principal",
      input: %{effect_key: label}
    )
  end

  # {1, :<name>} in external term format, where <name> is an atom that has
  # never existed in this VM (SMALL_ATOM_UTF8_EXT, tag 119).
  defp hostile_term_bytes do
    name = "zz_never_an_atom_#{System.unique_integer([:positive])}"
    {name, <<131, 104, 2, 97, 1, 119, byte_size(name)>> <> name}
  end

  describe "TQ-04 :safe decoding" do
    test "an outbox entry that would mint a new atom is refused as :bad_term and mints nothing",
         %{dir: dir} do
      {name, bytes} = hostile_term_bytes()
      File.write!(Path.join(dir, "runtime:hostile.receipt"), bytes)

      assert [{"runtime:hostile.receipt", :bad_term}] = ReceiptOutbox.corrupt_entries()
      assert ReceiptOutbox.entries() == []
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    test "EvidenceChain.decode_receipt/1 refuses atom-minting bytes as :bad_term" do
      {name, bytes} = hostile_term_bytes()
      assert {:error, :bad_term} = EvidenceChain.decode_receipt(bytes)
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    test "EvidenceChain.decode_receipt/1 round-trips a real journal entry" do
      cmd = command("chain-roundtrip")
      receipt = Receipt.pending(cmd, Identity.execution("chain-exec"), :external_do)

      assert {:ok, ^receipt} =
               receipt |> EvidenceChain.encode_receipt() |> EvidenceChain.decode_receipt()
    end

    test "garbage bytes are skipped by read and reconcile, never a crash", %{dir: dir} do
      File.write!(Path.join(dir, "runtime:garbage.receipt"), <<131, 255>>)

      name = :"outbox_hardening_store_#{System.unique_integer([:positive])}"
      start_supervised!({Memory, name: name})

      assert ReceiptOutbox.entries() == []
      assert {:ok, %{committed: 0, remaining: 1}} = ReceiptOutbox.reconcile(Memory, name: name)
      assert [{"runtime:garbage.receipt", _reason}] = ReceiptOutbox.corrupt_entries()
    end
  end

  describe "R5 command-keyed anchors" do
    test "a torn command-keyed entry anchors only its own command" do
      owner = command("torn-owner")
      other = command("torn-other")

      File.write!(ReceiptOutbox.entry_path_for(owner.command_id, Identity.runtime("t")), <<131>>)

      assert ReceiptOutbox.anchored_command?(owner.command_id)
      refute ReceiptOutbox.anchored_command?(other.command_id)
    end

    test "an outbox dir that exists but cannot be listed anchors every command (fail closed)",
         %{dir: dir} do
      # A real permission failure on the real journal directory: the anchor
      # evidence is unobservable, so no claim may be judged abandoned.
      File.chmod!(dir, 0o000)

      try do
        assert {:error, :eacces} = File.ls(dir)
        assert ReceiptOutbox.anchored_command?(command("unlistable").command_id)
      after
        File.chmod!(dir, 0o755)
      end
    end

    test "a torn legacy-named entry still blocks every command (fail closed)", %{dir: dir} do
      File.write!(Path.join(dir, "runtime:torn.receipt"), <<131, 104>>)
      assert ReceiptOutbox.anchored_command?(command("legacy-any").command_id)
    end

    test "append/1 writes the command-keyed name and anchored?/1 + remove/1 agree" do
      cmd = command("append")
      receipt = Receipt.pending(cmd, Identity.execution("append-exec"), :external_do)

      assert :ok = ReceiptOutbox.append(receipt)
      assert File.regular?(ReceiptOutbox.entry_path_for(cmd.command_id, receipt.receipt_id))
      assert ReceiptOutbox.anchored?(receipt)
      assert ReceiptOutbox.anchored_command?(cmd.command_id)

      assert :ok = ReceiptOutbox.remove(receipt)
      refute ReceiptOutbox.anchored?(receipt)
      refute ReceiptOutbox.anchored_command?(cmd.command_id)
    end

    test "migrate_legacy/0 rewrites a readable legacy entry into the command-keyed format",
         %{dir: dir} do
      cmd = command("migrate")
      receipt = Receipt.pending(cmd, Identity.execution("migrate-exec"), :external_do)
      legacy = Path.join(dir, Identity.external(receipt.receipt_id) <> ".receipt")
      File.write!(legacy, EvidenceChain.encode_receipt(receipt))

      assert ReceiptOutbox.anchored_command?(cmd.command_id)
      assert 1 = ReceiptOutbox.migrate_legacy()
      refute File.exists?(legacy)
      assert File.regular?(ReceiptOutbox.entry_path_for(cmd.command_id, receipt.receipt_id))
      assert [^receipt] = ReceiptOutbox.entries()
    end
  end

  describe "R4 reconcile re-claim" do
    test "an outboxed receipt re-claimed into an empty store keeps its execution id and binding" do
      name = :"outbox_hardening_reclaim_#{System.unique_integer([:positive])}"
      start_supervised!({Memory, name: name})

      cmd = command("reclaim")
      original = Identity.execution("original-exec")

      receipt =
        cmd
        |> Receipt.pending(original, :external_do)
        |> Receipt.finalize({:reply, :done})

      assert :ok = ReceiptOutbox.append(receipt)
      assert {:ok, %{committed: 1, remaining: 0}} = ReceiptOutbox.reconcile(Memory, name: name)

      assert {:ok, stored} = Memory.fetch(cmd.command_id, name: name)
      assert stored.execution_id == original
      assert stored.terminal_status == :reconciled
      assert {:ok, _report} = Binding.check(stored)
      # The re-created claim is owned by that execution (fencing holds).
      assert :ok = Memory.confirm_claim(cmd.command_id, original, name: name)
    end
  end

  describe "OBS-09 corrupt entries raise a standing signal" do
    test "a Reconciler tick emits :corrupt with the filename and counts it in :tick", %{dir: dir} do
      File.write!(Path.join(dir, "runtime:corrupt.receipt"), <<1, 2, 3>>)

      store = :"outbox_hardening_reconciler_store_#{System.unique_integer([:positive])}"
      start_supervised!({Memory, name: store})
      reconciler = :"outbox_hardening_reconciler_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Reconciler,
         name: reconciler, interval_ms: 3_600_000, store: Memory, store_opts: [name: store]}
      )

      parent = self()
      handler = "outbox-hardening-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler,
        [
          [:ash_a2a, :receipt_outbox, :reconciler, :corrupt],
          [:ash_a2a, :receipt_outbox, :reconciler, :tick]
        ],
        fn event, measurements, metadata, _ -> send(parent, {event, measurements, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, %{remaining: 1}} = Reconciler.tick(reconciler)

      assert_receive {[:ash_a2a, :receipt_outbox, :reconciler, :corrupt], %{count: 1},
                      %{filenames: ["runtime:corrupt.receipt"]}}

      assert_receive {[:ash_a2a, :receipt_outbox, :reconciler, :tick], %{corrupt: 1}, _}
    end
  end
end
