defmodule AshA2A.ConsequenceKernel.W4.Route do
  @moduledoc false
  @type t :: :observe | :consequence | :refused
  def classify(:observe), do: :observe
  def classify(c) when c in [:change, :external_do], do: :consequence
  def classify(_), do: :refused
end
