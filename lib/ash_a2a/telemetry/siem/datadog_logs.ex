# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Telemetry.SIEM.DatadogLogs do
  @moduledoc """
  Datadog Logs HTTP intake adapter (`AshA2A.Telemetry.SIEM` behaviour).

  Wire shape: `POST {endpoint}/api/v2/logs` with `DD-API-KEY: <api_key>` and
  a JSON body of Datadog log items whose `message` is the OCEL v2 event's
  ndjson line (so the intake-visible log text is exactly the OCEL v2
  serialization, byte-for-byte decodable) plus Datadog routing attributes.
  Config:

    * `:endpoint` (required) -- e.g. `https://http-intake.logs.datadoghq.com`
    * `:api_key` (required) -- sent only as the `DD-API-KEY` header
    * `:service` (optional, default `"ash_a2a"`) -- Datadog `service` facet
    * `:ddsource` (optional, default `"ash_a2a"`) -- Datadog `source` facet
    * shared keys documented on `AshA2A.Telemetry.SIEM`
  """

  @behaviour AshA2A.Telemetry.SIEM

  alias AshA2A.Telemetry.SIEM

  @default_service "ash_a2a"
  @default_ddsource "ash_a2a"
  @path "/api/v2/logs"

  @impl true
  def platform, do: :datadog_logs

  @impl true
  def validate_config(config) do
    with :ok <- SIEM.common_config(config),
         :ok <- SIEM.require_credential(config, :api_key),
         :ok <- SIEM.optional_binary(config, :service),
         :ok <- SIEM.optional_binary(config, :ddsource) do
      {:ok, config}
    end
  end

  @impl true
  def send_events(events, config) do
    body =
      Jason.encode!(%{
        "data" =>
          Enum.map(events, fn event ->
            %{
              "type" => "log",
              "attributes" => %{
                "message" => Jason.encode!(event),
                "ddsource" => config[:ddsource] || @default_ddsource,
                "service" => config[:service] || @default_service,
                "status" => "info"
              }
            }
          end)
      })

    headers = [
      {"dd-api-key", Keyword.fetch!(config, :api_key)},
      {"content-type", "application/json"}
    ]

    SIEM.request(config, @path, headers, body)
  end
end
