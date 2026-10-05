# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.AuthorityBinding do
  @moduledoc "Checks explicit authority identity and constraints independently from the finding."

  def admit(authority, command, scope, budget)
      when is_map(authority) and is_map(command) and is_map(scope) do
    principal = AshA2A.Gall.Fields.get(command, :principal_id)
    capability = AshA2A.Gall.Fields.get(command, :capability_id)
    constraints = AshA2A.Gall.Fields.get(authority, :constraints) || %{}

    cond do
      AshA2A.Gall.Fields.get(authority, :subject) != principal ->
        {:error, {:refused_gall, :authority_binding, :principal_mismatch}}

      AshA2A.Gall.Fields.get(authority, :capability_id) != capability ->
        {:error, {:refused_gall, :authority_binding, :capability_mismatch}}

      constraint(constraints, :scope) != scope ->
        {:error, {:refused_gall, :authority_binding, :scope_mismatch}}

      constraint(constraints, :max_consequences) != 1 ->
        {:error, {:refused_gall, :authority_binding, :budget_mismatch}}

      budget not in [1, %{max_consequences: 1}, %{"max_consequences" => 1}] ->
        {:error, {:refused_gall, :authority_binding, :invalid_budget}}

      true ->
        {:ok, authority}
    end
  end

  def admit(_, _, _, _), do: {:error, {:refused_gall, :authority_binding, :invalid_authority}}

  defp constraint(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end
