defmodule AshA2A.ConsequenceKernel.W4.Outcome do
  @moduledoc false
  def classify({:ok, _}), do: :completed
  def classify({:error, %{outcome_known?: false}}), do: :unknown_outcome
  def classify({:error, _}), do: :failed
  def classify(_), do: :unknown_outcome
end
