# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Telemetry.SIEM.SplunkHEC do
  @moduledoc """
  Splunk HTTP Event Collector (HEC) adapter (`AshA2A.Telemetry.SIEM` behaviour).

  Wire shape: `POST {endpoint}/services/collector/event` with
  `Authorization: Splunk <token>` and one ndjson line per event:

      {"time": <epoch_seconds_float>, "event": <OCEL v2 event>,
       "sourcetype": "...", "index": "..."}

  `time` is parsed from the event's OCEL `"event_time"` (ISO 8601), falling
  back to wall-clock submit time when unparseable. Config:

    * `:endpoint` (required) -- e.g. `https://splunk.example:8088`
    * `:token` (required) -- HEC token, sent only as the auth header
    * `:sourcetype` (optional, default `"ash_a2a:ocel:v2"`)
    * `:index` (optional) -- target Splunk index
    * shared keys documented on `AshA2A.Telemetry.SIEM`
  """

  @behaviour AshA2A.Telemetry.SIEM

  alias AshA2A.Telemetry.SIEM

  @default_sourcetype "ash_a2a:ocel:v2"

  @impl true
  def platform, do: :splunk_hec

  @impl true
  def validate_config(config) do
    with :ok <- SIEM.common_config(config),
         :ok <- SIEM.require_credential(config, :token),
         :ok <- SIEM.optional_binary(config, :sourcetype),
         :ok <- SIEM.optional_binary(config, :index) do
      {:ok, config}
    end
  end

  @impl true
  def send_events(events, config) do
    now_ms = System.system_time(:millisecond)

    body = SIEM.ndjson(Enum.map(events, &hec_line(&1, config, now_ms)))

    headers = [
      {"authorization", "Splunk " <> Keyword.fetch!(config, :token)},
      {"content-type", "application/x-ndjson"}
    ]

    SIEM.request(config, "/services/collector/event", headers, body)
  end

  defp hec_line(event, config, now_ms) do
    %{"time" => epoch_seconds(event, now_ms), "event" => event}
    |> Map.put("sourcetype", config[:sourcetype] || @default_sourcetype)
    |> put_index(config[:index])
  end

  defp epoch_seconds(event, now_ms) do
    case DateTime.from_iso8601(event["event_time"]) do
      {:ok, dt, _offset} -> DateTime.to_unix(dt, :millisecond) / 1000
      _ -> now_ms / 1000
    end
  end

  defp put_index(map, nil), do: map
  defp put_index(map, index), do: Map.put(map, "index", index)
end
