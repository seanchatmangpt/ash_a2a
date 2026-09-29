defmodule AshA2A.ConsequenceKernel.RefusalCodes.Authority do
  @moduledoc false
  @codes [:authority_unknown_decision, :kernel_bypass, :effector_contract_violation]
  def codes, do: @codes
  def authority_related?(c), do: c in @codes
end
