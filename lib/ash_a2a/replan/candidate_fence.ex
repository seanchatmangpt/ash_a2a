defmodule AshA2A.Replan.CandidateFence do
  def check(%{authority: :none, standing: :candidate}), do: :ok
  def check(_), do: {:error, AshA2A.Replan.Refusal.new(:replan_authority_violation)}
end
