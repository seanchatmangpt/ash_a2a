defmodule AshA2A.Gall.Closure.Provenance do
  @moduledoc "Manufactures an immutable provenance envelope from the exact admitted subjects."

  alias AshA2A.Gall.Closure.Determinism

  def build(candidate, task \\ nil) when is_map(candidate) do
    envelope = %{
      producer_repository: field(candidate, :producer_repository),
      producer_sha: field(candidate, :producer_sha),
      evidence_digest: field(candidate, :evidence_digest),
      semantic_subject_digest: field(candidate, :semantic_subject_digest),
      candidate_digest: field(candidate, :candidate_digest),
      task_id: task,
      authority: :none,
      standing: :candidate
    }

    Map.put(envelope, :provenance_digest, Determinism.digest(envelope))
  end

  def valid?(%{provenance_digest: digest} = envelope) do
    digest == envelope |> Map.delete(:provenance_digest) |> Determinism.digest()
  end

  def valid?(_), do: false

  defp field(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end
