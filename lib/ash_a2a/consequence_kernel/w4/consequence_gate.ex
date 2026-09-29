defmodule AshA2A.ConsequenceKernel.W4.ConsequenceGate do
  @moduledoc false
  alias AshA2A.ConsequenceKernel.W4.Route
  def admit(c) do
    case Route.classify(c) do
      :consequence -> :ok
      :observe -> {:error, :not_consequential}
      :refused -> {:error, :consequence_unclassified}
    end
  end
end
