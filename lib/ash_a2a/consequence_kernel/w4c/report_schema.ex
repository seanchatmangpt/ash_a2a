defmodule AshA2A.ConsequenceKernel.W4C.ReportSchema do
  def valid?(%{edges: edges}) when is_list(edges), do: true
  def valid?(_), do: false
end
