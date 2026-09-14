defmodule AshA2A.CapabilityIndex.Compiler do
  @moduledoc """
  Derives the A2A capability index from canonical Ash introspection.

  The compiler never creates business semantics. Its input set is exactly
  `Ash.Resource.Info.public_actions/1`; optional `a2a skill` declarations are
  residual projection overrides keyed by `{resource, action}`.
  """

  alias AshA2A.Argument
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
      consequence: override_value(override, :consequence, default_consequence(action.type)),
      arguments: derive_arguments(resource, action)
    }
  end

  # Derives real per-skill argument type data from canonical Ash
  # introspection. `AshA2A.Skill`'s own @moduledoc states the intent ("Action
  # arguments are always derived from Ash introspection"); this is where
  # that intent is actually implemented -- previously this field was
  # hardcoded to `[]` regardless of what the real action declared.
  #
  # Two real Ash introspection surfaces feed this list:
  #
  #   1. `action.arguments` -- real `Ash.Resource.Actions.Argument.t()`
  #      structs declared directly on the action
  #      (`deps/ash/lib/ash/resource/actions/argument.ex`: `name`, `type`,
  #      `public?`, among others). Only `public?: true` arguments are
  #      included -- the same filter
  #      `AshA2A.CapabilityIndex.AgentCardBuilder.input_names/1` already
  #      applies to the wire-facing tags/description text, so a non-public
  #      argument is treated the same way on both the wire projection and
  #      this in-process one: not a real callable input for an external
  #      caller.
  #
  #   2. `action.accept` -- for `:create`/`:update` actions, the list of
  #      directly-accepted attribute names
  #      (`deps/ash/lib/ash/resource/actions/create.ex`/`update.ex`:
  #      `accept: nil | list(atom)`).
  #
  #      Design decision, stated explicitly rather than silently picked:
  #      accepted attributes ARE represented as `AshA2A.Argument` entries
  #      here, not omitted. Rationale --
  #      `AshA2A.CapabilityIndex.AgentCardBuilder.input_names/1` already
  #      folds `accept` names into the same "inputs" list as real action
  #      arguments for the wire card's tags/description
  #      (`argument_names ++ accept_names`), i.e. this codebase already
  #      treats an accepted attribute as an equally real callable input to
  #      an action argument. An in-process composer calling
  #      `AshA2A.Info.skill/2` needs the same completeness the wire
  #      projection's prose already implies: it cannot tell "declared
  #      argument" from "accepted attribute" apart from the outside (both
  #      are just named, typed inputs it may supply), so hiding accepted
  #      attributes from `arguments` here would make this the *less*
  #      complete of the two projections despite being the one meant to
  #      carry real typed argument data. Each accepted attribute's real
  #      type comes from `Ash.Resource.Info.attribute(resource,
  #      name).type` (the real `Ash.Resource.Attribute.t()`), never
  #      guessed or left untyped.
  #
  #      If `action.accept` names an attribute introspection cannot find
  #      (should not happen on a resource that compiled successfully, but
  #      Ash does not make this statically impossible -- e.g. a stale
  #      `accept` list after an attribute rename), that name is silently
  #      skipped rather than raising: a capability index deriving step must
  #      never crash resource compilation over a residual accept-list
  #      mismatch.
  #
  # Declared arguments are listed before accept-derived entries, and the
  # combined list is de-duplicated by name (first occurrence wins) in case
  # a declared argument and an accepted attribute ever share a name.
  @spec derive_arguments(module(), Ash.Resource.Actions.action()) :: [Argument.t()]
  defp derive_arguments(resource, action) do
    argument_entries =
      action
      |> Map.get(:arguments, [])
      |> Enum.filter(&Map.get(&1, :public?, true))
      |> Enum.map(&%Argument{name: &1.name, type: &1.type})

    accept_entries =
      action
      |> Map.get(:accept)
      |> List.wrap()
      |> Enum.map(&accepted_attribute_argument(resource, &1))
      |> Enum.reject(&is_nil/1)

    (argument_entries ++ accept_entries)
    |> Enum.uniq_by(& &1.name)
  end

  defp accepted_attribute_argument(resource, attribute_name) do
    case Ash.Resource.Info.attribute(resource, attribute_name) do
      nil -> nil
      attribute -> %Argument{name: attribute.name, type: attribute.type}
    end
  end

  # Repository-native default consequence per real Ash action type
  # (`AshA2A.Skill`'s own @moduledoc documents the full rationale): `:read`
  # is unambiguously non-consequence-bearing;
  # `:create`/`:update`/`:destroy` are unambiguously consequence-bearing via
  # the canonical Ash data layer. A generic `:action` has no safe default --
  # `action.type` alone cannot tell a pure calculation from a real
  # mutating/externally-effecting operation -- so it defaults to `:unknown`
  # and stays there (fail-closed for `CommandBus`/`AshA2A.Agent` admission)
  # until a resource author explicitly declares `consequence:` on its
  # `a2a do skill ... end` entry.
  defp default_consequence(:read), do: :observe
  defp default_consequence(:create), do: :change
  defp default_consequence(:update), do: :change
  defp default_consequence(:destroy), do: :change
  defp default_consequence(_generic_action), do: :unknown

  defp override_value(nil, _field, default), do: default
  defp override_value(override, field, default), do: Map.get(override, field) || default

  defp resource_overrides(resource) do
    case Extension.get_persisted(resource, :ash_a2a_skill_overrides, nil) do
      overrides when is_list(overrides) -> overrides
      _ -> []
    end
  end
end
