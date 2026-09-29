defmodule AshA2A.C2.EffectorRegistry do
  def fetch(effect, registry) do
    case Map.fetch(registry,effect.capability) do
      {:ok, effector} when is_atom(effector) -> {:ok,effector}
      :error -> {:error,:unknown_effector}
    end
  end
end
