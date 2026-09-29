defmodule AshA2A.ConsequenceKernel.Ocel do
  def project(prepared, outcome) do
    %{
      "ocel:type" => "SA2A.Consequence",
      "effect_id" => prepared.instance.effect_id,
      "prepared_digest" => prepared.prepared_digest,
      "outcome" => to_string(outcome),
      "subject_digest" => prepared.instance.subject_digest
    }
  end
end
