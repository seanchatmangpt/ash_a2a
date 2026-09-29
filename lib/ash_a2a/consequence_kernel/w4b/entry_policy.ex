defmodule AshA2A.ConsequenceKernel.W4B.EntryPolicy do
  @moduledoc false
  @consequential [:change, :external_do]
  def admit(:observe, :observation), do: :ok
  def admit(:observe, :kernel), do: :ok
  def admit(c, :kernel) when c in @consequential, do: :ok
  def admit(:unknown, _), do: {:error, :consequence_unclassified}
  def admit(c, _) when c in @consequential, do: {:error, :consequence_kernel_required}
  def admit(_, _), do: {:error, :invalid_consequence}
end
