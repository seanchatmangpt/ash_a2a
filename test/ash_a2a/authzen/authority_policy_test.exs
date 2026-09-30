defmodule AshA2A.AuthZEN.AuthorityPolicyTest do
  use ExUnit.Case, async: true
  alias AshA2A.AuthZEN.{AuthorityPolicy, PolicyEvidence}
  alias AshA2A.C2.{AuthorityRequest, Certificate, PreparedEffect}

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

  test "external allow only unlocks a local authority-domain issuer" do
    effect = PreparedEffect.new("principal:alice", :payments, %{"id" => 1}, %{})
    ctx = %{policy_epoch: 1, revocation_epoch: 2, generation: 3, audience: "actuator:payments"}
    request = AuthorityRequest.new(effect, ctx)

    evidence = %PolicyEvidence{
      decision: true,
      policy_decision_point: "https://pdp.example",
      principal: effect.principal,
      effect_digest: effect.digest,
      observed_at: 1
    }

    policy_ctx = Map.merge(ctx, %{
      authzen_evidence: evidence,
      authzen_expected_pdp: "https://pdp.example",
      local_certificate_issuer: LocalIssuer
    })

    assert :ok = AuthorityPolicy.admit(request, policy_ctx)
    assert {:ok, %Certificate{effect_digest: digest}} = AuthorityPolicy.issue(request, policy_ctx)
    assert digest == effect.digest
  end
end
