defmodule AshA2A.Marketplace.GCP.Metering do
  @moduledoc """
  Formats and validates usage reports against the Google Service Control API
  (`servicecontrol.googleapis.com/v1/services/{service}:report`).

  Permits enterprise customers to draw down their committed Google Cloud spend (EDP)
  proportionate to agent executions and plan solutions.
  """

  @service_name "ecosystem.marketplace.endpoints.google.com"

  @type metric_value :: %{
          metric_name: String.t(),
          value: integer(),
          start_time: DateTime.t(),
          end_time: DateTime.t()
        }

  @doc "Builds an idempotent Service Control report payload for Google Cloud billing."
  @spec build_report_payload(String.t(), [metric_value()], keyword()) :: map()
  def build_report_payload(usage_reporting_id, metrics, opts \\ []) do
    service = Keyword.get(opts, :service_name, @service_name)
    operation_id = Keyword.get(opts, :operation_id, "op-#{System.unique_integer([:positive])}")

    operations = [
      %{
        "operationId" => operation_id,
        "operationName" => "MarketplaceUsageReporting",
        "consumerId" => "project:#{usage_reporting_id}",
        "startTime" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "endTime" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "metricValueSets" =>
          Enum.map(metrics, fn m ->
            %{
              "metricName" => m.metric_name,
              "metricValues" => [
                %{
                  "int64Value" => to_string(m.value),
                  "startTime" => m.start_time |> DateTime.to_iso8601(),
                  "endTime" => m.end_time |> DateTime.to_iso8601()
                }
              ]
            }
          end)
      }
    ]

    %{
      "serviceName" => service,
      "operations" => operations
    }
  end

  @doc "Validates that a metric item matches allowed usage dimensions."
  @spec valid_metric_name?(String.t()) :: boolean()
  def valid_metric_name?(metric_name) do
    metric_name in [
      "ash_a2a.googleapis.com/agent_executions",
      "ash_pplan.googleapis.com/plan_solves",
      "ash_ex4pm.googleapis.com/conformance_checks"
    ]
  end
end
