defmodule AshA2A.KernelReceiptTest do
  use ExUnit.Case, async: true

  test "receipt binds prepared identity" do
    p = %{
      instance: %{effect_id: "e", subject_digest: "s"},
      prepared_digest: "p",
      authority_epoch: 1
    }

    assert {:ok, r} = AshA2A.ConsequenceKernel.Receipt.issue(p, :ok)
    assert r.effect_id == "e"
    assert r.receipt_digest =~ "sha256:"
  end
end
