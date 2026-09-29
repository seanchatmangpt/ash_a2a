defmodule AshA2A.ConsequenceKernel.CompleteMediation do
  @forbidden [AshA2A.Dispatcher]
  def forbidden_modules, do: @forbidden
  def admit_call_path(modules) when is_list(modules) do
    if Enum.any?(modules, &(&1 in @forbidden)), do: {:error, :kernel_bypass}, else: :ok
  end
end
