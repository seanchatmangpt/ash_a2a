# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Telemetry.MetricsTest do
  use ExUnit.Case, async: true

  alias AshA2A.Telemetry.Metrics

  test "every definition names a real :ash_a2a event and a measurement" do
    defs = Metrics.definitions()
    assert length(defs) >= 8

    for d <- defs do
      assert [:ash_a2a | _] = d.event
      assert d.type in [:summary, :distribution, :counter, :last_value]
      full = Enum.map_join(d.event ++ [d.measurement], ".", &Atom.to_string/1)

      # A counter counts occurrences, so it may be named `<event>.count`
      # (dropping a trailing :stop span suffix) instead of by measurement.
      count_name =
        d.event
        |> Enum.reject(&(&1 == :stop))
        |> Enum.map_join(".", &Atom.to_string/1)
        |> Kernel.<>(".count")

      base_name =
        d.event
        |> Enum.reject(&(&1 == :stop))
        |> Enum.map_join(".", &Atom.to_string/1)

      stripped_name = base_name <> "." <> Atom.to_string(d.measurement)

      assert d.name == full or d.name == stripped_name or
               (d.type == :counter and d.name == count_name),
             "#{d.name} matches none of #{full}, #{stripped_name}, #{count_name}"
    end
  end

  test "metrics/0 fails with a clear message when :telemetry_metrics is absent" do
    if Code.ensure_loaded?(Telemetry.Metrics) do
      assert length(Metrics.metrics()) == length(Metrics.definitions())
    else
      assert_raise ArgumentError, ~r/requires the :telemetry_metrics dependency/, fn ->
        Metrics.metrics()
      end
    end
  end
end
