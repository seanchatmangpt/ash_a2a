defmodule AshA2A.ConsequenceKernel.W5.IndependentClaim do
  def admit(r, e) when is_binary(r) and is_binary(e) and r != e, do: :ok
  def admit(_, _), do: {:error, :independent_effect_claim_required}
end
