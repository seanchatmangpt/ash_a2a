defmodule AshA2A.ConsequenceKernel.SourceCallGraph do
  @moduledoc false
  alias AshA2A.ConsequenceKernel.CallEdge

  @kernel "AshA2A.ConsequenceKernel"
  @dispatcher "AshA2A.Dispatcher"
  @ash_effect ~r/\bAsh\.(create|update|destroy|run_action|bulk_create|bulk_update|bulk_destroy)!?\b/

  def project(source, subject) when is_binary(source) and is_binary(subject) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, n} -> project_line(line, n, subject) end)
  end

  defp project_line(line, n, subject) do
    cond do
      String.contains?(line, @kernel <> ".execute") -> [edge(line, n, subject, AshA2A.ConsequenceKernel, :kernel)]
      String.contains?(line, @dispatcher <> ".dispatch") -> [edge(line, n, subject, AshA2A.Dispatcher, :dispatcher)]
      Regex.match?(@ash_effect, line) -> [edge(line, n, subject, Ash, :ash_effect)]
      Regex.match?(~r/\bapply\s*\(/, line) -> [edge(line, n, subject, :dynamic, :dynamic, true)]
      true -> []
    end
  end

  defp edge(line, n, subject, callee, kind, dynamic? \\ false) do
    {:ok, edge} = CallEdge.new(%{caller: __MODULE__, callee: callee, kind: kind, subject: subject, source: String.trim(line), line: n, dynamic?: dynamic?})
    edge
  end
end
