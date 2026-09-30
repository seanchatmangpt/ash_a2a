defmodule AshA2A.ConsequenceKernel.CompleteMediation do
  @moduledoc false
  alias AshA2A.ConsequenceKernel.CallEdge
  @forbidden [AshA2A.Dispatcher]
  def forbidden_modules, do: @forbidden

  def admit_call_path(modules) when is_list(modules) do
    if Enum.any?(modules, &(&1 in @forbidden)), do: {:error, :kernel_bypass}, else: :ok
  end

  def admit_call_edge(%CallEdge{kind: :kernel}), do: :ok
  def admit_call_edge(%CallEdge{kind: :neutral}), do: :ok
  def admit_call_edge(%CallEdge{kind: :dispatcher}), do: {:error, :kernel_bypass}
  def admit_call_edge(%CallEdge{kind: :ash_effect}), do: {:error, :direct_effect_bypass}
  def admit_call_edge(%CallEdge{kind: :dynamic}), do: {:error, :unresolved_dynamic_consequence}
  def admit_call_edge(_), do: {:error, :unknown_call_edge}
end
