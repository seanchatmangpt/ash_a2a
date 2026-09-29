defmodule AshA2A.ConsequenceKernel.Runtime.Result do
  def normalize({:ok,v}), do: {:completed,v}
  def normalize({:unknown,r}), do: {:unknown_outcome,r}
  def normalize({:error,r}), do: {:unknown_outcome,{:effector_error_after_apply_boundary,r}}
  def normalize(other), do: {:unknown_outcome,{:invalid_effector_result,other}}
end
