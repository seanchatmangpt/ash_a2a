defmodule AshA2A.CapabilityIndex.Compiler do
  @moduledoc """
  Derives the A2A capability index from canonical Ash introspection.

  The compiler never creates business semantics. Its input set is exactly
  `Ash.Resource.Info.public_actions/1`; optional `a2a skill` declarations are
  residual projection overrides keyed by `{resource, action}`.
  """

  alias AshA2A.Skill
  alias Spark.Dsl.Extension

  @spec compile(module(), :resource | :domain, [Skill.t()]) :: [Skill.t()]
  def compile(subject, :resource, overrides) when is_list(overrides) do
    compile_resource(subject, overrides)
  end

  def compile(subject, :domain, domain_overrides) when is_list(domain_overrides) do
    subject
    |> Ash.Domain.Info.resources()
    |> Enum.flat_map(fn resource ->
      compile_resource(resource, resource_overrides(resource) ++ domain_overrides)
    end)
    |> Enum.sort_by(& &1.id)
  end

  @doc "Stable default A2A capability id for a canonical Ash action."
  @spec capability_id(module(), atom()) :: String.t()
  def capability_id(resource, action) do
    "#{inspect(resource)}.#{action}"
  end

  defp compile_resource(resource, overrides) do
    override_by_action =
      overrides
      |> Enum.filter(&(&1.resource == resource))
      |> Map.new(fn override -> {override.action, override} end)

    resource
    |> Ash.Resource.Info.public_actions()
    |> Enum.reduce([], fn action, skills ->
      override = Map.get(override_by_action, action.name)

      if override && override.expose? == false do
        skills
      else
        [project(resource, action, override) | skills]
      end
    end)
    |> Enum.sort_by(& &1.id)
  end

  defp project(resource, action, override) do
    %Skill{
      id: capability_id(resource, action.name),
      name: override_value(override, :name, action.name),
      resource: resource,
      domain: Ash.Resource.Info.domain(resource),
      action: action.name,
      description: override_value(override, :description, nil),
      tags: override_value(override, :tags, nil),
      expose?: true,
      arguments: []
    }
  end

  defp override_value(nil, _field, default), do: default
  defp override_value(override, field, default), do: Map.get(override, field) || default

  defp resource_overrides(resource) do
    case Extension.get_persisted(resource, :ash_a2a_skill_overrides, nil) do
      overrides when is_list(overrides) -> overrides
      _ -> []
    end
  end
end
