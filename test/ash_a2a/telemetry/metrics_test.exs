defmodule AshA2A.Telemetry.MetricsTest do
  use ExUnit.Case, async: true

  alias AshA2A.Telemetry.Metrics

  test "every definition names a real :ash_a2a event and a measurement" do
    defs = Metrics.definitions()
    assert length(defs) >= 8

    for d <- defs do
      assert [:ash_a2a | _] = d.event
      assert d.type in [:summary, :distribution, :counter, :last_value]
      assert d.name == Enum.map_join(d.event ++ [d.measurement], ".", &Atom.to_string/1)
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
