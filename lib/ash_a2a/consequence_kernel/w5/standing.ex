defmodule AshA2A.ConsequenceKernel.W5.Standing do
  alias AshA2A.ConsequenceKernel.W5.{ClaimAuthenticator, ClaimReceipt, ReplayEvidence}

  def derive(c, rs, replay, outcome, key) do
    with :ok <- ClaimAuthenticator.verify(c, key),
         :ok <- ClaimReceipt.verify_chain(rs),
         :ok <- ReplayEvidence.verify(c, replay),
         :ok <- outcome_ok(outcome),
         do: {:ok, :evidenced}
  end

  defp outcome_ok(s) when s in [:completed, :reconciled_completed], do: :ok

  defp outcome_ok(s) when s in [:unknown_outcome, :reconciled_unknown],
    do: {:error, :standing_unknown_outcome}

  defp outcome_ok(_), do: {:error, :standing_not_established}
end
