defmodule AshA2A.ConsequenceKernel.W4B.CallPathPolicy do
  @moduledoc false
  @allowed %{observe: [:agent_observation, :kernel], change: [:kernel], external_do: [:kernel]}
  def admit(consequence, caller),
    do:
      if(caller in Map.get(@allowed, consequence, []), do: :ok, else: {:error, :raw_effect_path})
end
