defmodule AshA2A.ConsequenceKernel.Runtime.Invariant do
  alias AshA2A.ConsequenceKernel.Runtime.Transition
  def transition_path?(states), do: states |> Enum.chunk_every(2,1,:discard) |> Enum.all?(fn [a,b] -> Transition.valid?(a,b) end)
end
