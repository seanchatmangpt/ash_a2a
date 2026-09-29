defmodule AshA2A.ConsequenceKernel.W4.UnknownOutcome do
  @moduledoc false
  def retry?(:unknown_outcome), do: false
  def retry?(_), do: true
  def disposition(:unknown_outcome), do: :reconcile
  def disposition(_), do: :none
end
