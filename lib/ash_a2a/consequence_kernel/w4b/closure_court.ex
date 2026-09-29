defmodule AshA2A.ConsequenceKernel.W4B.ClosureCourt do
  @moduledoc false
  alias AshA2A.ConsequenceKernel.W4B.EntryPolicy
  def judge(vectors) when is_list(vectors), do: Enum.map(vectors, fn %{consequence: c, route: r, expected: e} -> {c, r, EntryPolicy.admit(c, r) == e} end)
  def closed?(results), do: Enum.all?(results, fn {_, _, ok?} -> ok? end)
end
