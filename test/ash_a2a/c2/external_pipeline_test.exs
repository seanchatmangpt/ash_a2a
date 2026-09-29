defmodule AshA2A.C2.ExternalPipelineTest do
  use ExUnit.Case, async: true

  alias AshA2A.C2.{ActuationPipeline, AuthorityResponse, Certificate, PreparedEffect}

  defmodule Authority do
    @behaviour AshA2A.C2.AuthorityClient
    def authorize(request, _ctx) do
      cert = %Certificate{
        version: 1,
        effect_digest: request.effect_digest,
        principal: request.principal,
        policy_epoch: request.policy_epoch,
        revocation_epoch: request.revocation_epoch,
        generation: request.generation,
        nonce: "n1",
        not_before_ms: 0,
        expires_at_ms: 10_000,
        audience: request.audience,
        threshold: 1,
        signatures: [%{"key_id" => "external"}]
      }

      {:ok, AuthorityResponse.admit(cert)}
    end
  end

  defmodule Actuator do
    @behaviour AshA2A.C2.ActuatorClient
    def execute(effect, cert, _ctx) do
      send(self(), {:actuator_called, effect.digest, cert.effect_digest})
      {:ok, %{"state" => "executed", "effect_digest" => effect.digest}}
    end
  end

  test "protected pipeline crosses authority and actuator client boundaries" do
    effect = PreparedEffect.new("principal:alice", :payments, %{"id" => 42}, %{"amount" => 100})
    ctx = %{policy_epoch: 1, revocation_epoch: 2, generation: 3, audience: "actuator:payments"}

    assert {:ok, %{"state" => "executed"}} =
             ActuationPipeline.execute(effect, ctx, Authority, Actuator)

    assert_received {:actuator_called, effect_digest, certificate_digest}
    assert effect_digest == certificate_digest
  end
end
