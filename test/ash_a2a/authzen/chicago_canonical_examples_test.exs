# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.AuthZEN.ChicagoCanonicalExamplesTest do
  use ExUnit.Case, async: true

  alias AshA2A.AuthZEN.{Metadata, Types, Wire}
  alias AshA2A.SPIFFE.{AttestedIdentity, Identity, PDPBinding}

  @authzen_figure_14 %{
    "subject" => %{
      "type" => "user",
      "id" => "alice@example.com"
    },
    "resource" => %{
      "type" => "account",
      "id" => "123"
    },
    "action" => %{
      "name" => "can_read",
      "properties" => %{
        "method" => "GET"
      }
    },
    "context" => %{
      "time" => "1985-10-26T01:22-07:00"
    }
  }

  test "AuthZEN 1.0 Figure 14 survives the internal model and wire boundary byte-for-shape" do
    request = %Types.Request{
      subject: %Types.Entity{type: "user", id: "alice@example.com"},
      resource: %Types.Entity{type: "account", id: "123"},
      action: %Types.Action{name: "can_read", properties: %{"method" => "GET"}},
      context: %{"time" => "1985-10-26T01:22-07:00"}
    }

    assert Wire.request(request) == @authzen_figure_14
  end

  test "AuthZEN decisions remain strict booleans and preserve decision context" do
    assert {:ok, decision} =
             Wire.decode_decision(%{
               "decision" => false,
               "context" => %{"reason" => "resource not found"}
             })

    refute decision.decision
    assert decision.context == %{"reason" => "resource not found"}
    assert {:error, :invalid_decision} = Wire.decode_decision(%{"decision" => "false"})
  end

  test "SPIFFE published workload identity example preserves trust-domain and path identity" do
    assert {:ok, identity} = Identity.parse("spiffe://prod.acme.com/billing/api")
    assert identity.uri == "spiffe://prod.acme.com/billing/api"
    assert identity.trust_domain == "prod.acme.com"
    assert identity.path == "/billing/api"
  end

  test "verified X509-SVID identity can bind a PDP but still contributes no authority by itself" do
    assert {:ok, metadata} =
             Metadata.decode(%{"policy_decision_point" => "https://pdp.example.com"})

    assert {:ok, attested} =
             AttestedIdentity.from_verified("spiffe://prod.acme.com/billing/api",
               svid_type: :x509,
               bundle_digest: "sha256:canonical-example-bundle",
               observed_at: 1
             )

    binding = %PDPBinding{
      policy_decision_point: "https://pdp.example.com",
      spiffe_id: "spiffe://prod.acme.com/billing/api",
      trust_domain: "prod.acme.com"
    }

    assert :ok = PDPBinding.admit(metadata, attested, binding)

    jwt = %{attested | svid_type: :jwt}
    assert {:error, :spiffe_pdp_binding_mismatch} = PDPBinding.admit(metadata, jwt, binding)
  end
end
