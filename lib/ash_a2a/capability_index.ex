defmodule AshA2A.CapabilityIndex do
  @moduledoc """
  Public facade for the derived Ash-to-A2A capability projection.

  The capability index is not authored or persisted as a second business
  model. `AshA2A.Info` derives it from `Ash.Resource.Info.public_actions/1`
  through `AshA2A.CapabilityIndex.Compiler`. This facade keeps wire projection
  and residual-override validation separate.
  """

  @type skill :: AshA2A.Skill.t()
  @type refusal :: %{code: atom(), detail: String.t()}

  @doc "Builds a deterministic real `A2A.AgentCard.t()` from a derived index."
  @spec build_agent_card([skill()], keyword()) :: A2A.AgentCard.t()
  defdelegate build_agent_card(skills, opts \\ []), to: AshA2A.CapabilityIndex.AgentCardBuilder

  @doc """
  Validates optional residual A2A skill overrides.

  An override is admitted only when it points to an existing public Ash
  action. It cannot expose a private action or manufacture a missing one.
  """
  @spec validate([skill() | map()]) :: :ok | {:error, [refusal()]}
  defdelegate validate(skills), to: AshA2A.CapabilityIndex.Validator
end
