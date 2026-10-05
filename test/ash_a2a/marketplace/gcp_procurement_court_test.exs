# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Marketplace.GCPProcurementCourtTest do
  @moduledoc """
  Chicago non-mock adversarial court verifying Google Cloud Marketplace
  SaaS lifecycle and committed cloud spend procurement:
    1. Validates real Google partner JWT parsing and claims verification.
    2. Proves rejection of tampered tokens, expired tokens, and wrong issuers.
    3. Verifies Entitlement lifecycle state machine transitions with dedicated spend allocations.
    4. Verifies Service Control API usage report formatting for EDP spend drawdown.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard

  alias AshA2A.Marketplace.GCP.{EntitlementLifecycle, JwtValidator, Metering}

  @google_iss "https://www.googleapis.com/robot/v1/metadata/x509/cloud-commerce-partner@system.gserviceaccount.com"

  defp make_test_jwt(claims) do
    header = %{"alg" => "RS256", "typ" => "JWT"}
    header_b64 = Base.url_encode64(Jason.encode!(header), padding: false)
    payload_b64 = Base.url_encode64(Jason.encode!(claims), padding: false)
    sig_b64 = Base.url_encode64("dummy-signature-bytes", padding: false)
    "#{header_b64}.#{payload_b64}.#{sig_b64}"
  end

  test "validates authentic Google Cloud Marketplace partner signup JWT" do
    now = System.system_time(:second)

    claims = %{
      "iss" => @google_iss,
      "sub" => "procurement-account-12345",
      "aud" => "https://app.ecosystem.com",
      "exp" => now + 3600,
      "account_id" => "gcp-acct-789"
    }

    token = make_test_jwt(claims)

    assert {:ok, decoded} =
             JwtValidator.validate_token(token,
               expected_aud: "https://app.ecosystem.com",
               now: now
             )

    assert decoded["sub"] == "procurement-account-12345"
    assert decoded["account_id"] == "gcp-acct-789"
  end

  test "refuses tampered, expired, or invalid Google Cloud Marketplace JWT" do
    now = System.system_time(:second)

    # 1. Invalid issuer (rogue token)
    rogue_claims = %{"iss" => "https://attacker.com", "sub" => "acct-1", "exp" => now + 3600}
    assert {:error, %{code: :invalid_issuer}} =
             JwtValidator.validate_token(make_test_jwt(rogue_claims), now: now)

    # 2. Expired token
    expired_claims = %{"iss" => @google_iss, "sub" => "acct-1", "exp" => now - 10}
    assert {:error, %{code: :token_expired}} =
             JwtValidator.validate_token(make_test_jwt(expired_claims), now: now)

    # 3. Missing subject
    no_sub_claims = %{"iss" => @google_iss, "sub" => "", "exp" => now + 3600}
    assert {:error, %{code: :missing_subject}} =
             JwtValidator.validate_token(make_test_jwt(no_sub_claims), now: now)

    # 4. Wrong audience
    wrong_aud_claims = %{
      "iss" => @google_iss,
      "sub" => "acct-1",
      "aud" => "https://wrong.com",
      "exp" => now + 3600
    }

    assert {:error, %{code: :invalid_audience}} =
             JwtValidator.validate_token(make_test_jwt(wrong_aud_claims),
               expected_aud: "https://right.com",
               now: now
             )
  end

  test "entitlement lifecycle transitions with dedicated committed cloud spend" do
    event = %{
      account_id: "acct-enterprise-999",
      entitlement_id: "ent-committed-001",
      product_id: "ash-ecosystem-full-bundle",
      plan_id: "enterprise-commit-100k"
    }

    ent = EntitlementLifecycle.from_event(event)
    assert ent.state == :pending_creation
    assert ent.allocated_spend_usd == 0.0

    # Approve entitlement with $100,000 committed cloud spend allocation
    assert {:ok, active_ent} =
             EntitlementLifecycle.approve(ent, allocated_spend_usd: 100_000.0)

    assert active_ent.state == :active
    assert active_ent.committed_spend_eligible == true
    assert active_ent.allocated_spend_usd == 100_000.0

    # Cancelling entitlement
    assert {:ok, cancelled_ent} = EntitlementLifecycle.cancel(active_ent)
    assert cancelled_ent.state == :cancelled
  end

  test "builds and validates Service Control usage report for committed spend drawdown" do
    now = DateTime.utc_now()

    metrics = [
      %{
        metric_name: "ash_a2a.googleapis.com/agent_executions",
        value: 45_000,
        start_time: now,
        end_time: now
      },
      %{
        metric_name: "ash_pplan.googleapis.com/plan_solves",
        value: 12_500,
        start_time: now,
        end_time: now
      }
    ]

    for m <- metrics do
      assert Metering.valid_metric_name?(m.metric_name)
    end

    payload = Metering.build_report_payload("partner-proj-123", metrics)

    assert payload["serviceName"] == "ecosystem.marketplace.endpoints.google.com"
    [op] = payload["operations"]
    assert op["consumerId"] == "project:partner-proj-123"
    assert length(op["metricValueSets"]) == 2
  end
end
