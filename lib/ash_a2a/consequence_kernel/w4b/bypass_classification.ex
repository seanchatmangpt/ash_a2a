defmodule AshA2A.ConsequenceKernel.W4B.BypassClassification do
  @moduledoc false
  def classify(:observe), do: :non_consequential
  def classify(c) when c in [:change, :external_do], do: :consequential
  def classify(_), do: :unclassified
end
