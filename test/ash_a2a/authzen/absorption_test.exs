# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.AuthZEN.AbsorptionTest do
  use ExUnit.Case, async: true

  alias AshA2A.AuthZEN.{Absorption, Client, Metadata}
  alias AshA2A.C2.{AuthorityRequest, Certificate, PreparedEffect}
  alias AshA2A.SPIFFE.{AttestedIdentity, PDPBinding}

  defmodule LocalIssuer do
    def issue(request, _ctx) do
      {:ok, %Certificate{
        version: 1,
        effect_digest: request.effect_digest,
        principal: request.principal,
        policy_epoch: request.policy_epoch,
        revocation_epoch: request.revocation_epoch,
        generation: request.generation,
        nonce: "0123456789abcdef",
        not_before_ms: 0,
        expires_at_ms: 10_000,
        audience: request.audience,
        threshold: 1,
        signatures: []
      }}
    end
  end

  test "external policy and workload identity still terminate at local certificate issuance" do
    effect = PreparedEffect.new("principal:alice", :payments, %{"id" => 42}, %{"amount" => 100})
    ctx = %{
      policy_epoch: 1,
      revocation_epoch: 2,
      generation: 3,
      audience: "actuator:payments",
      local_certificate_issuer: LocalIssuer
    }
    request = AuthorityRequest.new(effect, ctx)

    {:ok, metadata} = Metadata.decode(%{"policy_decision_point" => "https://pdp.example"})

    client = %Client{
      metadata: metadata,
      transport: fn "https://pdp.example/access/v1/evaluation", body ->
        assert body["subject"]["id"] == "principal:alice"
        assert body["resource"]["id"] == effect.digest
        {:ok, %{"decision" => true, "context" => %{"reason" => "policy"}}}
      end
    }

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

    assert {:ok, response, receipt} = Absorption.authorize(request, client, attested, binding, ctx)
    assert response.decision == :admit
    assert %Certificate{} = response.certificate
    assert response.certificate.effect_digest == effect.digest
    assert receipt.authority == :none
    assert receipt.consequence == :evidence_only
  end

  test "PDP allow cannot bypass a SPIFFE binding mismatch" do
    effect = PreparedEffect.new("principal:alice", :payments, %{"id" => 42}, %{})
    ctx = %{policy_epoch: 1, revocation_epoch: 2, generation: 3, audience: "a", local_certificate_issuer: LocalIssuer}
    request = AuthorityRequest.new(effect, ctx)
    {:ok, metadata} = Metadata.decode(%{"policy_decision_point" => "https://pdp.example"})
    client = %Client{metadata: metadata, transport: fn _, _ -> {:ok, %{"decision" => true}} end}

    {:ok, attested} =
      AttestedIdentity.from_verified("spiffe://other.example/pdp",
        svid_type: :x509,
        bundle_digest: "sha256:bundle",
        observed_at: 1
      )

    binding = %PDPBinding{
      policy_decision_point: "https://pdp.example",
      spiffe_id: "spiffe://prod.example/pdp/authzen",
      trust_domain: "prod.example"
    }

    assert {:error, :spiffe_pdp_binding_mismatch} =
             Absorption.authorize(request, client, attested, binding, ctx)
  end
end
