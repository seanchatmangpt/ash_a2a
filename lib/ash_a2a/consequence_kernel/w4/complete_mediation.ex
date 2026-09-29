defmodule AshA2A.ConsequenceKernel.W4.CompleteMediation do
  @moduledoc false
  @allowed [AshA2A.ConsequenceKernel.W4.DispatchInversion]
  def allowed_caller?(caller), do: caller in @allowed

  def admit(caller),
    do: if(allowed_caller?(caller), do: :ok, else: {:error, :direct_dispatch_forbidden})
end
