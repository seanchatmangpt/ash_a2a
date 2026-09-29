defmodule AshA2A.ConsequenceKernel.PreparedEffectStore.Recovery do
  @terminal [:completed, :reconciled, :compensated, :refused]
  def disposition(%{state: s}) when s in @terminal, do: {:terminal, s}
  def disposition(%{state: :unknown_outcome}), do: {:reconcile, :unknown_outcome}
  def disposition(%{state: s}) when s in [:prepared, :claimed, :applying], do: {:resume, s}
  def disposition(_), do: {:error, :prepared_state_unknown}
end
