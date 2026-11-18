# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.TelemetryEnvelopeTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.TelemetryEnvelope

  test "telemetry records the boundary decision without conferring authority" do
    event =
      TelemetryEnvelope.event(
        :preflight,
        %{candidate_digest: "cand", command_id: "c1"},
        :admitted
      )

    assert event.event == [:ash_a2a, :gall, :closure, :preflight]
    assert event.measurements == %{count: 1}
    assert event.metadata.outcome == :admitted
    assert event.metadata.authority == :none
  end
end
