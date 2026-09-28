defmodule AshA2A.Gall.Closure.ScopePolicy do
  @moduledoc "Binds the intervention scope to the exact command input and optional target."

  alias AshA2A.Gall.Closure.Determinism

  def admit(scope, command) when is_map(scope) and is_map(command) do
    expected_input = Determinism.digest(AshA2A.Gall.Fields.get(command, :input) || %{})
    expected_target = AshA2A.Gall.Fields.get(command, :target)
    actual_input = AshA2A.Gall.Fields.get(scope, :input_digest)
    actual_target = AshA2A.Gall.Fields.get(scope, :target)

    cond do
      map_size(scope) == 0 ->
        {:error, {:refused_gall, :scope_policy, :empty_scope}}

      actual_input != expected_input ->
        {:error, {:refused_gall, :scope_policy, :input_digest_mismatch}}

      not is_nil(expected_target) and actual_target != expected_target ->
        {:error, {:refused_gall, :scope_policy, :target_mismatch}}

      true ->
        {:ok, scope}
    end
  end

  def admit(_, _), do: {:error, {:refused_gall, :scope_policy, :invalid_scope}}
end
