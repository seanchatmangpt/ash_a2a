defmodule AshA2A.ConsequenceKernel.W4B.RawEffectGuard do
  @moduledoc false
  def admit(%{consequence: c, fence: true}) when c in [:change, :external_do], do: :ok
  def admit(%{consequence: :observe, observation_only: true}), do: :ok
  def admit(%{consequence: :unknown}), do: {:error, :consequence_unclassified}
  def admit(_), do: {:error, :raw_effect_path}
end
