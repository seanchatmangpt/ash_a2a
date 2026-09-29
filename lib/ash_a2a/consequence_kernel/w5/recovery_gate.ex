defmodule AshA2A.ConsequenceKernel.W5.RecoveryGate do
  def retry(:reconciled_not_applied), do: :ok
  def retry(:unknown_outcome), do: {:error,:retry_forbidden_until_reconciliation}
  def retry(:doing), do: {:error,:retry_forbidden_while_doing}
  def retry(s) when s in [:completed,:reconciled_completed], do: {:error,:already_completed}
  def retry(_), do: {:error,:retry_not_admitted}
end
