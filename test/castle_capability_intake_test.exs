# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.CastleCapabilityIntakeTest do
  use ExUnit.Case, async: true

  @path Path.expand("../semantic/castle-capability-intake.ttl", __DIR__)

  test "external adapters and protocol knowledge terminate at the SA2A transport owner" do
    graph = File.read!(@path)

    assert graph =~ "50fdfa20c84205a80c6eb94e916cffbedc4b816e"
    assert graph =~ ~s(eco:ownerCapability "SA2A_TRANSPORT")
    assert length(Regex.scan(~r/a eco:ProjectedCapability/, graph)) == 3

    for repo <- [
          "seanchatmangpt/ash_atlassian",
          "seanchatmangpt/ash_planning_center",
          "seanchatmangpt/agile-protocol-specification"
        ] do
      assert graph =~ ~s(eco:sourceRepository "#{repo}")
    end

    assert graph =~ ~s(eco:projectionStanding "CANDIDATE")
    assert graph =~ ~s(eco:authorityCeiling "CONSTRUCT")
    refute graph =~ ~s(eco:authorityCeiling "DO")
    refute graph =~ ~s(eco:runtimePlacement "RUNTIME_CORE")
    refute graph =~ ~s(eco:runtimePlacement "CONSEQUENCE_CROWN")
  end
end
