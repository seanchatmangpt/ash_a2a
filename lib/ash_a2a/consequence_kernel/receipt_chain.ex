defmodule AshA2A.ConsequenceKernel.ReceiptChain do
  def next(previous_digest, receipt) do
    AshA2A.Identity.Canonical.digest(%{"previous" => previous_digest, "receipt" => receipt})
  end
end
