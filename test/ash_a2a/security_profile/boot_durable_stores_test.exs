# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SecurityProfile.BootDurableStoresTest do
  @moduledoc """
  RFC-SA2A-007 boot court for the durable claim store and keyed journal:
  `:strict` refuses a missing/in-memory/tmp-backed claim store and a weak
  HMAC key, and the real application start path calls the boot enforcement.
  Real snapshots and real compiled BEAM imports; no doubles.
  """
  use ExUnit.Case, async: false

  alias AshA2A.SA2A.Conformance.Checks.C1
  alias AshA2A.SecurityProfile.Boot

  defp durable, do: Path.join(File.cwd!(), "_build_boot_probe")

  defp good do
    %{
      outbox_key: String.duplicate("k", 32),
      outbox_dir: durable(),
      receipt_store: AshA2A.ReceiptStore.Ekv,
      capability_release_mode: :strict,
      authority_broker: AshA2A.Authority.Broker.Ekv,
      kill_switch_class: "prod",
      authority_policy: :broker,
      claim_store: AshA2A.ConsequenceKernel.EffectClaimStore.DurableFile,
      claim_store_dir: durable()
    }
  end

  defp codes(cfg), do: cfg |> then(&Boot.violations(:strict, &1)) |> Enum.map(& &1.code)

  test "a fully configured snapshot with the durable claim store has no violations" do
    assert codes(good()) == []
  end

  for {label, patch, code} <- [
        {"no claim store", %{claim_store: nil}, :claim_store_missing},
        {"in-memory claim store", %{claim_store: AshA2A.C2.MemoryClaimStore},
         :claim_store_not_durable},
        {"ETS claim store", %{claim_store: AshA2A.C2.ClaimStoreETS}, :claim_store_not_durable},
        {"tmp claim store dir", %{claim_store_dir: "/tmp/claims"}, :claim_store_dir_not_durable},
        {"unset claim store dir", %{claim_store_dir: nil}, :claim_store_dir_not_durable},
        {"short HMAC key", %{outbox_key: "short"}, :outbox_key_weak}
      ] do
    test "strict refuses #{label}" do
      assert unquote(code) in codes(Map.merge(good(), unquote(Macro.escape(patch))))
    end
  end

  test "the real snapshot/0 carries the claim-store facts" do
    snap = Boot.snapshot()
    assert Map.has_key?(snap, :claim_store)
    assert Map.has_key?(snap, :claim_store_dir)
  end

  test "Application.start/2 calls Boot.run!/0, which runs SecurityPreflight.check! and ReceiptStore.boot_check" do
    assert {:ok, app} = C1.imports(%{beam_binaries: %{}}, AshA2A.Application)
    assert {AshA2A.SecurityProfile.Boot, :run!, 0} in app
    assert {:ok, boot} = C1.imports(%{beam_binaries: %{}}, AshA2A.SecurityProfile.Boot)
    assert {AshA2A.Authority.SecurityPreflight, :check!, 1} in boot
    assert {AshA2A.ReceiptStore, :boot_check, 0} in boot
  end

  test "new refusal codes are declared with valid classes" do
    for mod <- [
          Boot,
          AshA2A.ConsequenceKernel.EffectClaimStore.DurableFile,
          AshA2A.ConsequenceKernel.PreparedEffectStore.Journal
        ] do
      for {code, class} <- mod.__sa2a_refusal_codes__() do
        assert is_atom(code)
        assert class in [:refused_receipt, :refused_authority, :refused_bounds]
      end
    end
  end
end
