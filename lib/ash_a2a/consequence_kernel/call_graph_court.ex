defmodule AshA2A.ConsequenceKernel.CallGraphCourt do
  @moduledoc false
  alias AshA2A.ConsequenceKernel.CompleteMediation

  def judge(edges) when is_list(edges) do
    Enum.reduce_while(edges, :ok, fn edge, :ok ->
      case CompleteMediation.admit_call_edge(edge) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, %{reason: reason, edge: edge}}}
      end
    end)
  end
end
