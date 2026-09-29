defmodule AshA2A.C2.WireContractTest do
  use ExUnit.Case, async: true

  alias AshA2A.C2.{AuthorityRequest, PreparedEffect, Wire}

  test "authority wire carries the exact PreparedEffect digest and audience" do
    effect = PreparedEffect.new("principal:alice", :payments, %{"id" => 42}, %{"amount" => 100})
    request =
      AuthorityRequest.new(effect, %{
        policy_epoch: 4,
        revocation_epoch: 5,
        generation: 6,
        audience: "actuator:payments"
      })

    assert {:ok, wire} = Wire.authority_request(request)
    assert wire["effect_digest"] == effect.digest
    assert wire["effect"]["principal"] == "principal:alice"
    assert wire["effect"]["capability"] == "payments"
    assert wire["audience"] == "actuator:payments"
  end
end
