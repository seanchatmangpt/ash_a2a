defmodule AshA2A.ConsequenceClass do
  @classes [:observe, :change, :external, :unknown]
  def classify(:read), do: {:ok, :observe}
  def classify(x) when x in [:create, :update, :destroy], do: {:ok, :change}
  def classify(x) when x in [:webhook, :network, :file, :process], do: {:ok, :external}
  def classify(_), do: {:ok, :unknown}
  def admitted?(x), do: x in @classes and x != :unknown
end
