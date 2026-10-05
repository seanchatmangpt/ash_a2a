# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Telemetry.Metrics do
  @moduledoc """
  Metric definitions for `:ash_a2a` telemetry, so a host can build SLO
  dashboards without hand-pairing start/stop events (OBS-11).

    * `definitions/0` -- plain data (`%{type, name, event, measurement,
      tags, unit}`), dependency-free, usable with any reporter.
    * `metrics/0` -- the same definitions as `Telemetry.Metrics` structs, for
      `TelemetryMetricsPrometheus`, `OpentelemetryTelemetry`, LiveDashboard,
      etc. Requires the host to depend on `:telemetry_metrics` (this library
      does not force it); without it `metrics/0` raises a clear error.

  Durations are `:native` time units as emitted by `:telemetry.span/3`;
  reporters convert via `unit: {:native, :millisecond}` (already set here).

  `ash_a2a.command_bus.actuate.stop.duration` is present only once
  `AshA2A.CommandBus` emits a `:duration` measurement on its
  `[:ash_a2a, :command_bus, :actuate, :stop]` event; until then that metric
  simply records nothing (reporters skip events lacking the measurement).
  """

  @telemetry_metrics Telemetry.Metrics

  @type definition :: %{
          type: :summary | :distribution | :counter | :last_value,
          name: String.t(),
          event: [atom()],
          measurement: atom(),
          tags: [atom()],
          unit: term()
        }

  @doc "Metric definitions as plain data."
  @spec definitions() :: [definition()]
  def definitions do
    [
      %{
        type: :summary,
        name: "ash_a2a.dispatch.stop.duration",
        event: [:ash_a2a, :dispatch, :stop],
        measurement: :duration,
        tags: [:skill_name, :reply_type, :stage],
        unit: {:native, :millisecond}
      },
      %{
        type: :counter,
        name: "ash_a2a.dispatch.exception.duration",
        event: [:ash_a2a, :dispatch, :exception],
        measurement: :duration,
        tags: [:skill_name, :kind],
        unit: {:native, :millisecond}
      },
      %{
        type: :distribution,
        name: "ash_a2a.command_bus.actuate.stop.duration",
        event: [:ash_a2a, :command_bus, :actuate, :stop],
        measurement: :duration,
        tags: [:capability_id],
        unit: {:native, :millisecond}
      },
      %{
        type: :counter,
        name: "ash_a2a.authority.decision.system_time",
        event: [:ash_a2a, :authority, :decision],
        measurement: :system_time,
        tags: [:outcome],
        unit: :unit
      },
      %{
        type: :counter,
        name: "ash_a2a.ocel.delivered.duration",
        event: [:ash_a2a, :ocel, :delivered],
        measurement: :duration,
        tags: [],
        unit: {:native, :millisecond}
      },
      %{
        type: :counter,
        name: "ash_a2a.ocel.failed.duration",
        event: [:ash_a2a, :ocel, :failed],
        measurement: :duration,
        tags: [:reason],
        unit: {:native, :millisecond}
      },
      %{
        type: :counter,
        name: "ash_a2a.ocel.shed.count",
        event: [:ash_a2a, :ocel, :shed],
        measurement: :count,
        tags: [],
        unit: :unit
      },
      %{
        type: :last_value,
        name: "ash_a2a.receipt_outbox.reconciler.tick.remaining",
        event: [:ash_a2a, :receipt_outbox, :reconciler, :tick],
        measurement: :remaining,
        tags: [],
        unit: :unit
      },
      %{
        type: :summary,
        name: "ash_a2a.health.checked.duration",
        event: [:ash_a2a, :health, :checked],
        measurement: :duration,
        tags: [:status],
        unit: {:native, :millisecond}
      }
    ]
  end

  @doc """
  `definitions/0` as `Telemetry.Metrics` structs. Raises when the host has
  not added `{:telemetry_metrics, "~> 1.0"}` to its dependencies.
  """
  @spec metrics() :: [struct()]
  def metrics do
    unless Code.ensure_loaded?(@telemetry_metrics) do
      raise ArgumentError,
            "AshA2A.Telemetry.Metrics.metrics/0 requires the :telemetry_metrics " <>
              "dependency; add {:telemetry_metrics, \"~> 1.0\"} to your mix.exs " <>
              "or use AshA2A.Telemetry.Metrics.definitions/0"
    end

    Enum.map(definitions(), fn d ->
      opts = [event_name: d.event, measurement: d.measurement, tags: d.tags] ++ unit_opt(d)
      apply(@telemetry_metrics, d.type, [d.name, opts])
    end)
  end

  defp unit_opt(%{unit: :unit}), do: []
  defp unit_opt(%{unit: unit}), do: [unit: unit]
end
