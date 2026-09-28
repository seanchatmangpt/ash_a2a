defmodule AshA2A.GallClosure.ProvenanceBinding do
  @moduledoc "Bounded GALL-029/030 guard for source_sha."
  def admit(%{source_sha: v} = s) when v not in [nil, false, ""],
    do: {:ok, Map.put(s, :gall_guard, :provenance_binding)}

  def admit(_), do: {:error, :missing_source_sha}
end
