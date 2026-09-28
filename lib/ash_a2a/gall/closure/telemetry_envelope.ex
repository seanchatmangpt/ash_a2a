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
            candidate_digest: AshA2A.Gall.Fields.get(subject, :candidate_digest),
            command_id: AshA2A.Gall.Fields.get(subject, :command_id),
            receipt_id: AshA2A.Gall.Fields.get(subject, :receipt_id),
            authority: :none
          },
          attrs
        )
    }
  end
end
