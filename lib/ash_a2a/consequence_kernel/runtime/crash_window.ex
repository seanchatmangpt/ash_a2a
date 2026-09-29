defmodule AshA2A.ConsequenceKernel.Runtime.CrashWindow do
  @moduledoc "Classifies restart evidence without converting ambiguity into retry."
  def disposition(:prepared), do: :safe_to_release
  def disposition(:claimed), do: :safe_to_release
  def disposition(:applying), do: :unknown_outcome
  def disposition(:unknown_outcome), do: :reconcile_required
  def disposition(x) when x in [:completed, :reconciled, :compensated], do: :terminal
  def disposition(_), do: :refuse
end
