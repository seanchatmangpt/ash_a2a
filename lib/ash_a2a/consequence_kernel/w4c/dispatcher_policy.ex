defmodule AshA2A.ConsequenceKernel.W4C.DispatcherPolicy do
  def classify(:dispatch), do: :consequence
  def classify(:dispatch_observe), do: :observation
end
