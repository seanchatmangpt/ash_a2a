defmodule AshA2A.CS2.Contract do
  @moduledoc """
  Stable adapter around the generated RFC-CS2-001 fleet projection.
  This module owns runtime shape; generated semantic values stay in GeneratedConsumer.
  """
  alias AshA2A.CS2.GeneratedConsumer

  def subject, do: GeneratedConsumer.subject()
  def authority_ceiling, do: GeneratedConsumer.authority_ceiling()
  def consumers, do: GeneratedConsumer.consumers()

  def evidence_packet(evidence, provenance \\ %{}) do
    GeneratedConsumer.packet(evidence)
    |> Map.put(:provenance, provenance)
    |> Map.put(:kind, :cs2_evidence_packet)
  end

  def triage_packet(evidence, novelty, provenance \\ %{}) do
    evidence_packet(evidence, provenance)
    |> Map.put(:novelty, novelty)
    |> Map.put(:kind, :cs2_triage_packet)
  end
end
