# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1W5ClaimStore.ClaimIdentityJcsTest do
  use ExUnit.Case, async: true

  test "claim_identity_jcs" do
    vector =
      Path.join([
        File.cwd!(),
        "priv",
        "sa2a",
        "c1",
        "w5_claim_store_vectors",
        "claim_identity_jcs.json"
      ])

    assert File.read!(vector) =~ "\"case\": \"claim_identity_jcs\""

    assert {:ok, "sha256:" <> d} =
             AshA2A.ConsequenceKernel.W5.ClaimIdentity.bind(
               "req",
               "eff",
               "sha256:prep",
               "sha256:sub"
             )

    assert byte_size(d) == 64
  end
end
