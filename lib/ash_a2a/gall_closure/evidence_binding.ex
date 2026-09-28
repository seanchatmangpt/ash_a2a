defmodule AshA2A.GallClosure.EvidenceBinding do
  @moduledoc "Bounded GALL-029/030 guard for evidence_id."
  def admit(%{evidence_id: v} = s) when v not in [nil, false, ""],
    do: {:ok, Map.put(s, :gall_guard, :evidence_binding)}

  def admit(_), do: {:error, :missing_evidence}
end
