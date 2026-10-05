# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.CallGraphCourt do
  @moduledoc false
  @kernel_prefix "Elixir.AshA2A.ConsequenceKernel"
  @forbidden MapSet.new(["Elixir.AshA2A.Dispatcher", "Elixir.AshA2A.Effector", "Elixir.AshA2A.C2.Effector"])
  def classify(edge) when is_map(edge) do
    caller = normalize(Map.get(edge, :caller) || Map.get(edge, "caller"))
    callee = normalize(Map.get(edge, :callee) || Map.get(edge, "callee"))
    operation = to_string(Map.get(edge, :operation) || Map.get(edge, "operation") || "")
    cond do
      String.starts_with?(callee, @kernel_prefix) -> {:admit, :kernel_mediated}
      MapSet.member?(@forbidden, callee) -> {:refuse, :legacy_bypass}
      caller == "" or callee == "" -> {:refuse, :incomplete_call_edge}
      operation in ["dispatch", "apply", "perform"] -> {:refuse, :direct_consequence_operation}
      true -> {:admit, :non_consequence_edge}
    end
  end
  def classify(_), do: {:refuse, :invalid_call_edge}
  defp normalize(v) when is_atom(v), do: Atom.to_string(v)
  defp normalize(v) when is_binary(v), do: v
  defp normalize(v), do: to_string(v)
end
