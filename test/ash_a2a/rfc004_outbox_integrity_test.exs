# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.RFC004OutboxIntegrityTest do
  @moduledoc "RFC-SA2A-004 section 12: integrity-protected prepare journal."
  use ExUnit.Case, async: false

  @moduletag :serial

  alias AshA2A.{Command, Identity, Receipt, ReceiptOutbox, ReceiptStore}

  setup do
    dir = Path.join(System.tmp_dir!(), "outbox_integrity_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    saved =
      for k <- [:receipt_outbox_dir, :receipt_outbox_key, :receipt_binding_key],
          do: {k, Application.fetch_env(:ash_a2a, k)}

    Application.put_env(:ash_a2a, :receipt_outbox_dir, dir)
    Application.delete_env(:ash_a2a, :receipt_outbox_key)
    Application.delete_env(:ash_a2a, :receipt_binding_key)

    on_exit(fn ->
      for {k, v} <- saved do
        case v do
          {:ok, val} -> Application.put_env(:ash_a2a, k, val)
          :error -> Application.delete_env(:ash_a2a, k)
        end
      end

      File.rm_rf!(dir)
    end)

    {:ok, dir: dir}
  end

  defp receipt do
    command = %Command{
      command_id: Identity.command("rfc004-outbox-#{System.unique_integer([:positive])}"),
      agent_id: Identity.agent("agent"),
      principal_id: Identity.principal("principal"),
      capability_id: Identity.runtime("cap"),
      input: %{},
      submitted_at: DateTime.utc_now(),
      fingerprint: "fp"
    }

    Receipt.pending(command, Identity.execution(Ash.UUIDv7.generate()), :external_do)
  end

  defp new_store do
    name = Module.concat(__MODULE__, "S#{System.unique_integer([:positive])}")
    {:ok, _} = GenServer.start(ReceiptStore.Memory, %{}, name: name)
    [name: name]
  end

  test "keyed append + reconcile round-trips" do
    Application.put_env(:ash_a2a, :receipt_outbox_key, "k1-secret")
    r = receipt()
    assert :ok = ReceiptOutbox.append(r)
    assert [%Receipt{}] = ReceiptOutbox.entries()

    assert {:ok, %{committed: 1, remaining: 0}} =
             ReceiptOutbox.reconcile(ReceiptStore.Memory, new_store())

    assert ReceiptOutbox.count() == 0
  end

  test "well-formed forged entry planted without the key is refused under a key" do
    r = receipt()
    # Planted while no key is configured (an attacker's write path).
    assert :ok = ReceiptOutbox.append(r)
    Application.put_env(:ash_a2a, :receipt_outbox_key, "k1-secret")

    opts = new_store()

    assert {:ok, %{committed: 0, remaining: 1}} =
             ReceiptOutbox.reconcile(ReceiptStore.Memory, opts)

    assert {:error, :not_found} = ReceiptStore.Memory.fetch(r.command_id, opts) |> normalize()
    assert [{_file, :outbox_untagged_entry}] = ReceiptOutbox.corrupt_entries()
    assert ReceiptOutbox.entries() == []
  end

  test "raw legacy term bytes are refused under a key" do
    r = receipt()
    File.mkdir_p!(ReceiptOutbox.dir())

    File.write!(
      ReceiptOutbox.entry_path_for(r.command_id, r.receipt_id),
      :erlang.term_to_binary({1, r})
    )

    Application.put_env(:ash_a2a, :receipt_binding_key, "binding-key")

    assert {:ok, %{committed: 0, remaining: 1}} =
             ReceiptOutbox.reconcile(ReceiptStore.Memory, new_store())
  end

  test "tampered bytes are refused" do
    Application.put_env(:ash_a2a, :receipt_outbox_key, "k1-secret")
    r = receipt()
    :ok = ReceiptOutbox.append(r)
    path = ReceiptOutbox.entry_path_for(r.command_id, r.receipt_id)
    bytes = File.read!(path)
    keep = byte_size(bytes) - 1
    <<head::binary-size(^keep), last>> = bytes
    File.write!(path, <<head::binary, Bitwise.bxor(last, 1)>>)

    assert [{_file, reason}] = ReceiptOutbox.corrupt_entries()
    assert reason in [:outbox_bad_tag]

    assert {:ok, %{committed: 0, remaining: 1}} =
             ReceiptOutbox.reconcile(ReceiptStore.Memory, new_store())
  end

  test "entry tagged under a different key is refused" do
    Application.put_env(:ash_a2a, :receipt_outbox_key, "k1-secret")
    :ok = ReceiptOutbox.append(receipt())
    Application.put_env(:ash_a2a, :receipt_outbox_key, "other-key")
    assert [{_f, :outbox_bad_tag}] = ReceiptOutbox.corrupt_entries()
  end

  test "no key: dev/test still round-trips" do
    r = receipt()
    assert :ok = ReceiptOutbox.append(r)
    assert ReceiptOutbox.anchored?(r)

    assert {:ok, %{committed: 1, remaining: 0}} =
             ReceiptOutbox.reconcile(ReceiptStore.Memory, new_store())
  end

  defp normalize({:ok, _} = ok), do: ok
  defp normalize(_), do: {:error, :not_found}
end
