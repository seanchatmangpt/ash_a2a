defmodule AshA2A.Gall.Closure.CapabilityPolicy do
  @moduledoc "Requires the capability to come from an admitted semantic rule and never from finding self-assertion."

  def admit(candidate, allowed_capabilities)
      when is_map(candidate) and is_list(allowed_capabilities) do
    capability = AshA2A.Gall.Fields.get(candidate, :capability_id)
    requested = AshA2A.Gall.Fields.get(candidate, :requested_capability_id)

    cond do
      not is_binary(capability) or capability == "" ->
        {:error, {:refused_gall, :capability_policy, :missing_capability}}

      capability not in allowed_capabilities ->
        {:error, {:refused_gall, :capability_policy, {:capability_not_admitted, capability}}}

      not is_nil(requested) and requested != capability ->
        {:error, {:refused_gall, :capability_policy, :self_promoted_capability}}

      true ->
        {:ok, candidate}
    end
  end

  def admit(_, _), do: {:error, {:refused_gall, :capability_policy, :invalid_policy}}
end
