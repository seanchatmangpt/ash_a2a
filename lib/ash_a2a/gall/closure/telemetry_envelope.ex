defmodule AshA2A.Gall.Closure.TelemetryEnvelope do
  @moduledoc "Constructs boundary telemetry facts without claiming success or authority."

  def event(stage, subject, outcome, attrs \\ %{})
      when is_atom(stage) and is_map(subject) and is_atom(outcome) and is_map(attrs) do
    %{
      event: [:ash_a2a, :gall, :closure, stage],
      measurements: %{count: 1},
      metadata:
        Map.merge(
          %{
            outcome: outcome,
            candidate_digest: field(subject, :candidate_digest),
            command_id: field(subject, :command_id),
            receipt_id: field(subject, :receipt_id),
            authority: :none
          },
          attrs
        )
    }
  end

  defp field(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end
