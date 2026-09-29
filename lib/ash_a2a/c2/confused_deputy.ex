defmodule AshA2A.C2.ConfusedDeputy do
  def refuse?(requested, authenticated), do: requested != authenticated
end
