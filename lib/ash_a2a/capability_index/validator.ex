defmodule AshA2A.CapabilityIndex.Validator do
  @moduledoc """
  Fail-closed business-rule validation of a compiled A2A capability index.

  Extracted from `AshA2A.CapabilityIndex` (which remains the public facade
  and delegates `validate/1` here) to separate this module's concern --
  business-rule checking over a compiled index -- from `CapabilityIndex`'s
  other, unrelated concern (`AgentCardBuilder`'s wire-format AgentCard
  construction).

  Two checks, both fail-closed:

    * every skill name is unique across the compiled index;
    * every skill's `{resource, action}` pair names an action that actually
      exists on that resource, confirmed via the real
      `Ash.Resource.Info.action/2` introspection function
      (`~/xaas/deps/ash/lib/ash/resource/info.ex:716`,
      `def action(resource, name, type \\\\ nil)` — called here at arity 2).
  """

  @type skill :: AshA2A.Skill.t()
  @type refusal :: %{code: atom(), detail: String.t()}

  @doc """
  Fail-closed validation of a compiled capability index (see moduledoc): every
  skill name must be unique, and every skill's `{resource, action}` pair must
  name a real, existing action.

  ## Examples

      iex> skills = AshA2A.Info.capability_index(AshA2A.Test.Fixture.Echo)
      iex> AshA2A.CapabilityIndex.Validator.validate(skills)
      :ok

      iex> bad = %{name: :bogus, resource: AshA2A.Test.Fixture.Echo, action: :not_real}
      iex> {:error, [refusal]} = AshA2A.CapabilityIndex.Validator.validate([bad])
      iex> refusal.code
      :REFUSED_ACTION_NOT_FOUND

      iex> dup = %{name: :dup, resource: AshA2A.Test.Fixture.Echo, action: :read}
      iex> {:error, [refusal]} = AshA2A.CapabilityIndex.Validator.validate([dup, dup])
      iex> refusal.code
      :REFUSED_DUPLICATE_SKILL_NAME

  """
  @spec validate([skill()]) :: :ok | {:error, [refusal()]}
  def validate(skills) when is_list(skills) do
    refusals = validate_unique_names(skills) ++ validate_actions_exist(skills)

    if refusals == [], do: :ok, else: {:error, refusals}
  end

  defp validate_unique_names(skills) do
    skills
    |> Enum.frequencies_by(& &1.name)
    |> Enum.filter(fn {_name, count} -> count > 1 end)
    |> Enum.map(fn {name, count} ->
      %{
        code: :REFUSED_DUPLICATE_SKILL_NAME,
        detail:
          "skill name #{inspect(name)} is declared #{count} times; skill names must be unique"
      }
    end)
  end

  defp validate_actions_exist(skills) do
    Enum.flat_map(skills, fn %{name: name, resource: resource, action: action} ->
      case Ash.Resource.Info.action(resource, action) do
        nil ->
          [
            %{
              code: :REFUSED_ACTION_NOT_FOUND,
              detail:
                "skill #{inspect(name)} names action #{inspect(action)} on #{inspect(resource)}, " <>
                  "but no such action exists on that resource"
            }
          ]

        %{} ->
          []
      end
    end)
  end
end
