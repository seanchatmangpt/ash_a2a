defmodule AshA2A.ConsequenceKernel.Standing do
  def derive(%{outcome: :observed, receipt_verified?: true}), do: {:ok, :evidenced}
  def derive(%{outcome: :unknown}), do: {:error, :standing_unknown_outcome}
  def derive(_), do: {:error, :standing_evidence_missing}
end
