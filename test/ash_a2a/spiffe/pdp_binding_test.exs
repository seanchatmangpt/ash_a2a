# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SPIFFE.PDPBindingTest do
  use ExUnit.Case, async: true
  alias AshA2A.AuthZEN.Metadata
  alias AshA2A.SPIFFE.{AttestedIdentity, PDPBinding}

  test "binds exact PDP metadata to exact verified workload identity" do
    {:ok, metadata} = Metadata.decode(%{"policy_decision_point" => "https://pdp.example"})
    {:ok, attested} =
      AttestedIdentity.from_verified("spiffe://prod.example/pdp/authzen",
        svid_type: :x509,
        bundle_digest: "sha256:bundle",
        observed_at: 1
      )

    binding = %PDPBinding{
      policy_decision_point: "https://pdp.example",
      spiffe_id: "spiffe://prod.example/pdp/authzen",
      trust_domain: "prod.example"
    }

    assert :ok = PDPBinding.admit(metadata, attested, binding)
    wrong = %{attested | identity: %{attested.identity | uri: "spiffe://prod.example/pdp/other"}}
    assert {:error, :spiffe_pdp_binding_mismatch} = PDPBinding.admit(metadata, wrong, binding)
  end
end
