# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.PostconditionPolicy do
  @moduledoc "Binds the expected postcondition before DO and verifies an independent observation afterward."

  alias AshA2A.Gall.Closure.Determinism

  def bind(expected) when is_map(expected) and map_size(expected) > 0 do
    {:ok, %{expected: expected, digest: Determinism.digest(expected)}}
  end

  def bind(_),
    do: {:error, {:refused_gall, :postcondition_policy, :expected_postcondition_required}}

  def verify(%{digest: digest}, observation) when is_map(observation) do
    independent = AshA2A.Gall.Fields.get(observation, :independent)
    status = AshA2A.Gall.Fields.get(observation, :status)
    observed = AshA2A.Gall.Fields.get(observation, :expected_postcondition_digest)

    cond do
      independent != true ->
        {:error, {:refused_gall, :postcondition_policy, :observer_not_independent}}

      status not in [:verified, "verified"] ->
        {:error, {:refused_gall, :postcondition_policy, :not_verified}}

      observed != digest ->
        {:error, {:refused_gall, :postcondition_policy, :subject_mismatch}}

      true ->
        {:ok, observation}
    end
  end

  def verify(_, _), do: {:error, {:refused_gall, :postcondition_policy, :invalid_observation}}
end
