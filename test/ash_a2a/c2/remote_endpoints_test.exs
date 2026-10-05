# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C2.RemoteEndpointsTest do
  use ExUnit.Case, async: true

  alias AshA2A.C2.{ActuatorClient, AuthorityClient, AuthorityRequest, Certificate, PreparedEffect}

  test "remote authority refuses before network when endpoint is absent" do
    effect = PreparedEffect.new("p", :cap, "s", %{})

    request =
      AuthorityRequest.new(effect, %{
        policy_epoch: 1,
        revocation_epoch: 1,
        generation: 1,
        audience: "a"
      })

    assert {:error, {:missing_c2_endpoint, :authority_endpoint}} =
             AuthorityClient.authorize(AuthorityClient.Remote, request, %{})
  end

  test "remote actuator refuses before network when endpoint is absent" do
    effect = PreparedEffect.new("p", :cap, "s", %{})

    cert = %Certificate{
      version: 1,
      effect_digest: effect.digest,
      principal: "p",
      policy_epoch: 1,
      revocation_epoch: 1,
      generation: 1,
      nonce: "n",
      not_before_ms: 0,
      expires_at_ms: 100,
      audience: "a",
      threshold: 1,
      signatures: []
    }

    assert {:error, {:missing_c2_endpoint, :actuator_endpoint}} =
             ActuatorClient.execute(ActuatorClient.Remote, effect, cert, %{})
  end
end
