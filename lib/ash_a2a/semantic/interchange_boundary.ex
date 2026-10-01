defmodule AshA2A.Semantic.InterchangeBoundary do
  @moduledoc false
  defstruct [:subject, :contract, :projection, :runtime, :technical_standing, :external_standing, :runtime_authority]
  def authorized?(%__MODULE__{runtime_authority: nil}), do: false
  def authorized?(%__MODULE__{}), do: true
end
