defmodule AshA2A.Attestation.GateGrantAllowlistTest do
  use ExUnit.Case, async: true

  alias AshA2A.Attestation.Gate

  # Hand-pinned from /Users/sac/xaas/lib/xaas/governance/approval_geofence_exception_grant.ex
  # attributes (id/org_id/identifier_or_cidr/ttl_hours); approved_at + area are the
  # enforcement-side projections recorded at approve time (see GateGrantAllowlist moduledoc).
  @now 1_700_000_000

  defp grant(overrides \\ []) do
    {area_overrides, top} = Keyword.split(overrides, [:area])
    Map.merge(
      %{
        grant_id: "g-1",
        org_id: "org-1",
        identifier_or_cidr: "203.0.113.0/24",
        ttl_hours: 24,
        approved_at: @now - 60,
        area: Map.merge(
          %{"lat" => 37.0, "lon" => -122.0, "radius_km" => 2000.0},
          case area_overrides[:area] do
            nil -> %{}
            %{} = m -> m
            kw -> Map.new(kw, fn {k, v} -> {Atom.to_string(k), v} end)
          end
        )
      },
      Map.new(top)
    )
  end

  # ~1255 km apart in under 60s — an impossible jump unless granted.
  defp jumping_obs do
    [
      %{"lat" => 37.0, "lon" => -122.0, "timestamp" => @now - 30},
      %{"lat" => 47.0, "lon" => -115.0, "timestamp" => @now}
    ]
  end

  test "approved in-scope grant overrides the jump; same coordinates without/expired/out-of-scope still refuse" do
    assert Gate.verify_gps_trajectory(jumping_obs()) == {:refused, :gps_impossible_jump}

    assert Gate.verify_gps_trajectory(jumping_obs(),
             now: @now,
             approved_grants: [grant()]
           ) == :ok

    unapproved_area =
      grant(area: %{"lat" => 35.0, "lon" => 139.0, "radius_km" => 10.0})

    assert Gate.verify_gps_trajectory(jumping_obs(),
             now: @now,
             approved_grants: [unapproved_area]
           ) == {:refused, :gps_impossible_jump}

    expired = grant(approved_at: @now - 24 * 3600 - 1)
    assert Gate.verify_gps_trajectory(jumping_obs(),
             now: @now,
             approved_grants: [expired]
           ) == {:refused, :gps_impossible_jump}
  end

  test "no grants supplied: /2 is outcome-identical to /1, and non-jump refusals are never overridden" do
    assert Gate.verify_gps_trajectory(jumping_obs(), now: @now) ==
             Gate.verify_gps_trajectory(jumping_obs())

    malformed = [%{"lat" => "x", "lon" => 0.0, "timestamp" => 1}]

    assert Gate.verify_gps_trajectory(malformed,
             now: @now,
             approved_grants: [grant()]
           ) == {:refused, :spoofed_payload}
  end

  test "mutation probe: grant cover is computed on real distances, not constant-true" do
    assert Gate.verify_gps_trajectory(jumping_obs(),
             now: @now,
             approved_grants: [grant(area: [radius_km: 0.0])]
           ) == {:refused, :gps_impossible_jump}
  end
end
