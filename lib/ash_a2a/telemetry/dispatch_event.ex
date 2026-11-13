# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Telemetry.DispatchEvent do
  @moduledoc """
  The one OCEL v2 builder for `[:ash_a2a, :dispatch, :stop | :exception]`
  telemetry, shared by `AshA2A.Telemetry.OcelForwarder` (HTTP egress) and
  `AshA2A.Telemetry.OcelBroadcaster` (SIEM egress) so the two sinks can never
  disagree on event type, attributes (`stage`, `error`, `error_code`) or
  relationships.

  Every function is total over arbitrary metadata/measurement maps: it never
  raises, so it is safe to call inside a `:telemetry` handler (a raising
  handler is detached by `:telemetry`).

  `event_time` is an explicit argument (an ISO 8601 string captured at
  emission, in the emitting process) -- never sampled later in a GenServer
  flush.
  """

  alias AshA2A.Telemetry.Redact

  @doc "ISO 8601 UTC timestamp for `event_time`; call at emission."
  @spec now() :: String.t()
  def now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  @doc "OCEL event map for a `:dispatch, :stop` span."
  @spec stop(map(), map(), String.t()) :: map()
  def stop(measurements, metadata, event_time \\ now()) do
    build(event_type(metadata), stop_attributes(measurements, metadata), metadata, event_time)
  end

  @doc "OCEL event map for a `:dispatch, :exception` span."
  @spec exception(map(), map(), String.t()) :: map()
  def exception(measurements, metadata, event_time \\ now()) do
    attributes =
      measurements
      |> stop_attributes(metadata)
      |> Map.merge(%{
        "kind" => metadata |> Map.get(:kind) |> to_string_or_nil(),
        "error_code" => metadata |> Map.get(:reason) |> error_code()
      })

    build(event_type(metadata) <> ".exception", attributes, metadata, event_time)
  end

  @doc """
  `ash_a2a.dispatch.<resource short name>.<skill>`; never raises (a
  non-atom resource or a missing key degrades to `inspect/1`).
  """
  @spec event_type(map()) :: String.t()
  def event_type(metadata) when is_map(metadata) do
    resource = Map.get(metadata, :resource_or_domain)
    skill = Map.get(metadata, :skill_name)

    short_name =
      if is_atom(resource) and not is_nil(resource) and Ash.Resource.Info.resource?(resource) do
        Ash.Resource.Info.short_name(resource)
      else
        inspect(resource)
      end

    "ash_a2a.dispatch.#{short_name}.#{skill_label(skill)}"
  end

  def event_type(_other), do: "ash_a2a.dispatch.nil."

  @doc """
  Shared dispatch attribute map (also merged into receipt events by the
  forwarder): `skill_name`, `resource_or_domain`, `reply_type`,
  `duration_native`, plus `stage` and `error` when the span carries a stage.
  """
  @spec stop_attributes(map(), map()) :: map()
  def stop_attributes(measurements, metadata) do
    base = %{
      "skill_name" => skill_label(Map.get(metadata, :skill_name)),
      "resource_or_domain" => inspect(Map.get(metadata, :resource_or_domain)),
      "reply_type" => metadata |> Map.get(:reply_type) |> to_string_or_nil(),
      "duration_native" => measurements |> Map.get(:duration) |> to_string_or_nil()
    }

    case Map.get(metadata, :stage) do
      nil ->
        base

      stage ->
        base
        |> Map.put("stage", to_string_or_nil(stage))
        |> Map.put("error", error_code(Map.get(metadata, :error)))
    end
  end

  @doc "E2O relationships for the span's `:object_id`, else `[]`."
  @spec relationships(map()) :: [map()]
  def relationships(%{object_id: object_id}) when is_binary(object_id) and object_id != "" do
    [%{"qualifier" => "acted_on", "object_id" => object_id}]
  end

  def relationships(_metadata), do: []

  @doc """
  Redacted error KIND for an OCEL body (OBS-01): `"exception:<Module>"` for
  exceptions, otherwise the summary kind. Never a stacktrace or raw term.
  """
  @spec error_code(term()) :: String.t()
  def error_code(%{kind: :exception, exception: module}) when is_atom(module),
    do: "exception:" <> inspect(module)

  def error_code(%{__exception__: true, __struct__: module}), do: "exception:" <> inspect(module)

  def error_code(error) do
    case Redact.error_summary(error) do
      %{kind: :exception, exception: module} -> "exception:" <> inspect(module)
      %{kind: kind} -> to_string(kind)
    end
  end

  defp build(event_type, attributes, metadata, event_time) do
    %{
      "event_id" => Ash.UUIDv7.generate(),
      "event_type" => event_type,
      "event_time" => event_time,
      "attributes" => attributes,
      "relationships" => relationships(metadata)
    }
  end

  defp skill_label(nil), do: ""
  defp skill_label(skill) when is_atom(skill) or is_binary(skill), do: to_string(skill)
  defp skill_label(other), do: inspect(other)

  defp to_string_or_nil(nil), do: nil

  defp to_string_or_nil(value) when is_atom(value) or is_binary(value) or is_number(value),
    do: to_string(value)

  defp to_string_or_nil(value), do: inspect(value)
end
