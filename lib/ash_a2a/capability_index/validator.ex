defmodule AshA2A.CapabilityIndex.Validator do
  @moduledoc """
  Fail-closed validation for residual A2A skill overrides.

  Overrides may describe or suppress an existing capability, but they may not
  create one. Every `{resource, action}` pair must therefore name a real,
  public Ash action. Private actions remain internal even if explicitly named
  in the A2A DSL.
  """

  @type skill :: AshA2A.Skill.t() | map()
  @type refusal :: %{code: atom(), detail: String.t()}

  @spec validate([skill()]) :: :ok | {:error, [refusal()]}
  def validate(skills) when is_list(skills) do
    refusals = validate_unique_names(skills) ++ validate_actions(skills)
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
          "skill name #{inspect(name)} is declared #{count} times; skill override names must be unique"
      }
    end)
  end

  defp validate_actions(skills) do
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

        %{public?: false} ->
          [
            %{
              code: :REFUSED_ACTION_NOT_PUBLIC,
              detail:
                "skill override #{inspect(name)} names private action #{inspect(action)} on #{inspect(resource)}; " <>
                  "AshA2A only projects Ash.Resource.Info.public_actions/1"
            }
          ]

        %{} ->
          []
      end
    end)
  end
end
