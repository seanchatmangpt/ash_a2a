# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/sac/ash_a2a>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Verifiers.VerifySkills do
  @moduledoc """
  Compile-time verification of `a2a do skill ... end` declarations, so an
  invalid skill fails at compile time -- never at runtime when a remote
  agent hits the endpoint.

  Checks, per skill override (persisted by
  `AshA2A.Transformers.BuildCapabilityIndex` as `:ash_a2a_skill_overrides`):

    1. The resolved action exists on the skill's subject resource and is
       public. Delegated to the existing fail-closed helper
       `AshA2A.CapabilityIndex.Validator.validate/1`, raising
       `REFUSED_ACTION_NOT_FOUND` / `REFUSED_ACTION_NOT_PUBLIC` refusals
       (path `[:a2a]`).
    2. Every `argument_mapping` target (the map value atoms) is a real
       argument on the action -- a declared action argument or an accepted
       attribute (`action.arguments` ∪ `action.accept`); otherwise a
       DslError at `[:a2a, <skill_name>, :argument_mapping]` with code
       `refused_argument_mapping_target`.
    3. Argument types are JSON-Schema-serializable. Known non-serializable
       types (`:term`, `:struct`, `:function`, ...) are a compile-time
       DslError at `[:a2a, <skill_name>, :arguments]` with code
       `refused_type_not_json_serializable`; unknown/custom module types
       produce a compile-time WARNING in the `{:warn, ...}` style of
       `AshA2A.Verify`'s dead-argument warning.
    4. `lease_required? true` requires an authorizer on the subject that
       can evaluate leases. Without one, the lease gate cannot be enforced
       and dispatch under that skill would bypass the governance boundary
       -- refused at compile time with code
       `refused_lease_required_no_authorizer` at
       `[:a2a, <skill_name>, :lease_required?]`.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Transformer
  alias Spark.Dsl.Verifier

  # Types known to be un-representable in JSON Schema. Declaring one on an
  # A2A-exposed argument is a hard compile error: the wire projection could
  # never honestly describe it to a remote agent.
  @known_unserializable [
    :term,
    :struct,
    :function,
    :mfa,
    :module,
    :mapset,
    :tuple,
    :range,
    :regex,
    :pid,
    :reference
  ]

  # The serializable set: string, integer, number, boolean, map/keyword,
  # array, date/datetime/utc_datetime, uuid, atom-as-string.
  @serializable_atoms [
    :string,
    :integer,
    :number,
    :boolean,
    :date,
    :datetime,
    :utc_datetime,
    :uuid,
    :atom,
    :map,
    :keyword
  ]

  @impl true
  def verify(dsl_state) do
    overrides = Verifier.get_persisted(dsl_state, :ash_a2a_skill_overrides, [])

    if overrides == [] do
      :ok
    else
      with :ok <- validate_actions(overrides, dsl_state) do
        overrides
        |> Enum.flat_map(&check_skill(&1, dsl_state))
        |> summarize(dsl_state)
      end
    end
  end

  # -- Check 1: action existence / publicity, via the existing validator --

  defp validate_actions(overrides, dsl_state) do
    case AshA2A.CapabilityIndex.Validator.validate(overrides) do
      :ok ->
        :ok

      {:error, refusals} ->
        {:error,
         Spark.Error.DslError.exception(
           module: Verifier.get_persisted(dsl_state, :module),
           path: [:a2a],
           message: Enum.map_join(refusals, "; ", &"#{&1.code}: #{&1.detail}"),
           location: first_override_location(dsl_state, overrides)
         )}
    end
  end

  # -- Checks 2-4, per skill --

  # Returns a list of {:error, %Spark.Error.DslError{}} | {:warn, message}.
  defp check_skill(skill, dsl_state) do
    resource_subject? = Verifier.get_persisted(dsl_state, :ash_a2a_subject_kind) == :resource
    resource = skill_resource(skill, dsl_state, resource_subject?)

    case resolve_action(skill, dsl_state, resource_subject?) do
      {:error, %Spark.Error.DslError{}} = error ->
        [error]

      {:ok, action} ->
        type_results =
          action
          |> arguments_with_types(resource, dsl_state, resource_subject?)
          |> Enum.flat_map(&type_result(skill, &1, dsl_state))

        type_results ++
          argument_mapping_result(skill, action, dsl_state) ++
          lease_authorizer_result(skill, resource, dsl_state, resource_subject?)
    end
  end

  defp skill_resource(_skill, dsl_state, true), do: Verifier.get_persisted(dsl_state, :module)
  defp skill_resource(skill, _dsl_state, false), do: skill.resource

  defp resolve_action(skill, dsl_state, resource_subject?) do
    action =
      if resource_subject? do
        # The subject is still compiling: read through its in-flight
        # dsl_state instead of the module (same shape as the exemplar
        # ash_state_machine verifier, which reads Ash.Resource.Info from
        # dsl_state directly).
        Ash.Resource.Info.action(dsl_state, skill.action)
      else
        # Domain-level skill: the target resource is already compiled.
        safe_resource_action(skill.resource, skill.action)
      end

    case action do
      %{public?: true} = action ->
        {:ok, action}

      nil ->
        {:error,
         Spark.Error.DslError.exception(
           module: Verifier.get_persisted(dsl_state, :module),
           path: [:a2a, skill.name, :action],
           message:
             "refused_action_not_found: skill #{inspect(skill.name)} names action " <>
               "#{inspect(skill.action)} on #{inspect(skill.resource)}, but no such " <>
               "public action exists on that resource",
           location: Spark.Dsl.Entity.anno(skill)
         )}

      _other ->
        {:error,
         Spark.Error.DslError.exception(
           module: Verifier.get_persisted(dsl_state, :module),
           path: [:a2a, skill.name, :action],
           message:
             "refused_action_not_public: skill #{inspect(skill.name)} names private " <>
               "action #{inspect(skill.action)} on #{inspect(skill.resource)}; AshA2A " <>
               "only projects public actions",
           location: Spark.Dsl.Entity.anno(skill)
         )}
    end
  end

  defp safe_resource_action(resource, action) do
    Ash.Resource.Info.action(resource, action)
  rescue
    _ -> nil
  end

  defp argument_mapping_result(skill, action, dsl_state) do
    targets = skill |> Map.get(:argument_mapping, %{}) |> Map.values()
    real_names = real_argument_names(action)

    case Enum.find(targets, &(&1 not in real_names)) do
      nil ->
        []

      bogus ->
        [
          {:error,
           Spark.Error.DslError.exception(
             module: Verifier.get_persisted(dsl_state, :module),
             path: [:a2a, skill.name, :argument_mapping],
             message:
               "refused_argument_mapping_target: skill #{inspect(skill.name)} maps an " <>
                 "argument to #{inspect(bogus)}, but the action #{inspect(skill.action)} " <>
                 "has no such argument; real arguments are " <>
                 "#{inspect(Enum.sort(real_names))} (declared action arguments ∪ " <>
                 "accepted attributes)",
             location: Spark.Dsl.Entity.anno(skill)
           )}
        ]
    end
  end

  defp real_argument_names(action) do
    argument_names =
      action
      |> Map.get(:arguments, [])
      |> Enum.map(& &1.name)

    accept_names =
      action
      |> Map.get(:accept, [])
      |> List.wrap()

    Enum.uniq(argument_names ++ accept_names)
  end

  defp type_result(skill, %{name: name, type: type}, dsl_state) do
    case classify_type(type) do
      :serializable ->
        []

      {:unserializable, reason} ->
        [
          {:error,
           Spark.Error.DslError.exception(
             module: Verifier.get_persisted(dsl_state, :module),
             path: [:a2a, skill.name, :arguments],
             message:
               "refused_type_not_json_serializable: skill #{inspect(skill.name)} exposes " <>
                 "argument #{inspect(name)} of type #{inspect(type)}, which is not " <>
                 "JSON-Schema-serializable (#{reason}). The A2A wire projection cannot " <>
                 "honestly describe it to a remote agent; use a serializable type " <>
                 "(string, integer, number, boolean, map/keyword, array, " <>
                 "date/datetime/utc_datetime, uuid, atom-as-string) or set expose?: false.",
             location: Spark.Dsl.Entity.anno(skill)
           )}
        ]

      {:unknown, _type} ->
        [
          {:warn,
           "skill #{inspect(skill.name)} argument #{inspect(name)} has custom/unknown " <>
             "type #{inspect(type)}; AshA2A cannot prove it is JSON-Schema-serializable " <>
             "at compile time. Verify manually or use a primitive serializable type."}
        ]
    end
  end

  # Mirrors `AshA2A.CapabilityIndex.Compiler.derive_arguments/2`: declared,
  # public action arguments carry their own type; accepted attributes carry
  # the real attribute type from `Ash.Resource.Info.attribute/2`. Accept
  # names the resource cannot resolve are skipped (same defensive posture
  # as the compiler).
  defp arguments_with_types(action, resource, dsl_state, resource_subject?) do
    declared =
      action
      |> Map.get(:arguments, [])
      |> Enum.filter(&Map.get(&1, :public?, true))
      |> Enum.map(&%{name: &1.name, type: &1.type})

    accept_entries =
      action
      |> Map.get(:accept, [])
      |> List.wrap()
      |> Enum.map(&attribute_entry(&1, resource, dsl_state, resource_subject?))
      |> Enum.reject(&is_nil/1)

    declared ++ accept_entries
  end

  defp attribute_entry(name, _resource, dsl_state, true) do
    case Ash.Resource.Info.attribute(dsl_state, name) do
      nil -> nil
      attribute -> %{name: attribute.name, type: attribute.type}
    end
  end

  defp attribute_entry(name, resource, _dsl_state, false) do
    case safe_attribute(resource, name) do
      nil -> nil
      attribute -> %{name: attribute.name, type: attribute.type}
    end
  end

  defp safe_attribute(resource, name) do
    Ash.Resource.Info.attribute(resource, name)
  rescue
    _ -> nil
  end

  defp lease_authorizer_result(skill, resource, dsl_state, resource_subject?) do
    if Map.get(skill, :lease_required?, false) and not has_authorizer?(resource, dsl_state, resource_subject?) do
      [
        {:error,
         Spark.Error.DslError.exception(
           module: Verifier.get_persisted(dsl_state, :module),
           path: [:a2a, skill.name, :lease_required?],
           message:
             "refused_lease_required_no_authorizer: skill #{inspect(skill.name)} sets " <>
               "`lease_required? true`, but #{inspect(resource)} has no authorizer " <>
               "configured that can evaluate leases. The governance boundary cannot be " <>
               "enforced for this skill: dispatch would bypass authority entirely. " <>
               "Configure an authorizer (e.g. Ash.Policy.Authorizer policies or an " <>
               "AshA2A.Authority broker) on the resource, or remove `lease_required?`.",
           location: Spark.Dsl.Entity.anno(skill)
         )}
      ]
    else
      []
    end
  end

  # A resource-level subject is still compiling: read its `authorizers`
  # section entities straight from the in-flight dsl_state. A domain-level
  # skill's target resource is already compiled: `Ash.Resource.Info.authorizers/1`.
  # -- Type serializability classification --

  # Arrays/wrap-lists are serializable iff their item type is.
  defp classify_type({:array, inner}), do: classify_type(inner)
  defp classify_type({:wrap_list, inner}), do: classify_type(inner)

  # Module-form primitives: real resources declare `Ash.Type.String` etc.,
  # not the bare atoms. Normalize before classification (mirrors Ash's own
  # type aliases). Ordered before the generic atom catch-all.
  defp classify_type(Ash.Type.String), do: :serializable
  defp classify_type(Ash.Type.CiString), do: :serializable
  defp classify_type(Ash.Type.Integer), do: :serializable
  defp classify_type(Ash.Type.Boolean), do: :serializable
  defp classify_type(Ash.Type.Float), do: :serializable
  defp classify_type(Ash.Type.Decimal), do: :serializable
  defp classify_type(Ash.Type.Date), do: :serializable
  defp classify_type(Ash.Type.DateTime), do: :serializable
  defp classify_type(Ash.Type.Time), do: :serializable
  defp classify_type(Ash.Type.UUID), do: :serializable
  defp classify_type(Ash.Type.UUIDv7), do: :serializable
  defp classify_type(Ash.Type.Map), do: :serializable
  defp classify_type(Ash.Type.Struct), do: :serializable
  defp classify_type(Ash.Type.Atom), do: :serializable
  defp classify_type(Ash.Type.NewBase), do: :serializable
  defp classify_type(Ash.Type.Term), do: {:unserializable, "Ash.Type.Term values have no JSON representation"}

  # map/keyword with structured values: serializable.
  defp classify_type({container, _inner}) when container in [:map, :keyword, :keyword_list] do
    :serializable
  end

  defp classify_type(type) when is_atom(type) and type in @known_unserializable do
    {:unserializable, "#{inspect(type)} values have no JSON representation"}
  end

  defp classify_type(type) when is_atom(type) and type in @serializable_atoms do
    :serializable
  end

  # Case-insensitive strings serialize as strings.
  defp classify_type(:ci_string), do: :serializable

  # Any other atom is a custom/module type: not provably serializable, but
  # not known-bad either -- warn rather than error.
  defp classify_type(type) when is_atom(type), do: {:unknown, type}

  defp classify_type(type), do: {:unknown, type}

  defp has_authorizer?(_resource, dsl_state, true) do
    case Transformer.get_entities(dsl_state, [:authorizers]) do
      [_ | _] -> true
      _ -> false
    end
  end

  defp has_authorizer?(resource, _dsl_state, false) do
    match?([_ | _], safe_authorizers(resource))
  end

  defp safe_authorizers(resource) do
    Ash.Resource.Info.authorizers(resource)
  rescue
    _ -> []
  end

  defp summarize(results, _dsl_state) do
    {errors, warnings} =
      Enum.split_with(results, fn
        {:error, _} -> true
        {:warn, _} -> false
      end)

    case errors do
      [] ->
        case warnings do
          [] -> :ok
          _ -> {:warn, Enum.map(warnings, fn {:warn, message} -> message end)}
        end

      [{:error, %Spark.Error.DslError{} = first} | rest] ->
        message =
          if rest == [] do
            first.message
          else
            "#{first.message} (+ #{length(rest)} more skill verification failure(s) not shown)"
          end

        {:error,
         Spark.Error.DslError.exception(
           module: first.module,
           path: first.path,
           message: message,
           location: first.location
         )}
    end
  end

  defp first_override_location(dsl_state, [first | _]) do
    case Spark.Dsl.Entity.anno(first) do
      nil -> Spark.Dsl.Transformer.get_section_anno(dsl_state, [:a2a])
      anno -> anno
    end
  end

  defp first_override_location(dsl_state, []) do
    Spark.Dsl.Transformer.get_section_anno(dsl_state, [:a2a])
  end
end
