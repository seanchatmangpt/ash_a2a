# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Telemetry.SIEM.Chronicle do
  @moduledoc """
  Google Chronicle Ingestion API adapter (unstructured NDJSON log entries)
  for the `AshA2A.Telemetry.SIEM` behaviour.

  Wire shape: `POST {endpoint}/v2/logs?log_type=<log_type>` with
  `X-Goog-Api-Key: <api_key>` and one NDJSON line per raw OCEL v2 event
  (Chronicle's unstructured ingestion accepts newline-delimited JSON; the
  OCEL v2 object is carried verbatim so Chronicle parsers/YARA-L rules see
  `event_id`/`event_type`/`event_time`/`attributes` directly). Config:

    * `:endpoint` (required) -- e.g. the real
      `https://malachiteingestion-pa.googleapis.com`
    * `:api_key` (required) -- Chronicle ingestion API key
    * `:log_type` (optional, default `"ASH_A2A_OCEL"`)
    * shared keys documented on `AshA2A.Telemetry.SIEM`
  """

  @behaviour AshA2A.Telemetry.SIEM

  alias AshA2A.Telemetry.SIEM

  @default_log_type "ASH_A2A_OCEL"
  @path "/v2/logs"

  @impl true
  def platform, do: :chronicle

  @impl true
  def validate_config(config) do
    with :ok <- SIEM.common_config(config),
         :ok <- SIEM.require_credential(config, :api_key),
         :ok <- SIEM.optional_binary(config, :log_type) do
      {:ok, config}
    end
  end

  @impl true
  def send_events(events, config) do
    headers = [
      {"x-goog-api-key", Keyword.fetch!(config, :api_key)},
      {"content-type", "application/x-ndjson"}
    ]

    params = [log_type: config[:log_type] || @default_log_type]

    SIEM.request(config, @path, headers, SIEM.ndjson(events), params: params)
  end
end
