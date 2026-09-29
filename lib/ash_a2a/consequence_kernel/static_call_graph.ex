defmodule AshA2A.ConsequenceKernel.StaticCallGraph do
  @moduledoc "Conservative source-to-call-edge projection for C1 mediation courts. Projection only; authority=none."
  alias AshA2A.ConsequenceKernel.CompleteMediation
  @remote ~r/([A-Z][A-Za-z0-9_.]+)\.([a-z_][a-zA-Z0-9_!?]*)\s*\(/
  @local ~r/\b(apply|dispatch|perform)\s*\(/
  def extract(source, caller) when is_binary(source) do
    remote = for [_, callee, op] <- Regex.scan(@remote, source), do: %{caller: caller, callee: "Elixir." <> callee, operation: op}
    local = for [_, op] <- Regex.scan(@local, source), do: %{caller: caller, callee: caller, operation: op}
    Enum.uniq(remote ++ local)
  end
  def classify_source(source, caller), do: Enum.map(extract(source, caller), fn edge -> {edge, CompleteMediation.admit_call_edge(edge)} end)
end
