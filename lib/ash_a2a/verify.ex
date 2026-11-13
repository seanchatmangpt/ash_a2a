# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Verify do
  @moduledoc """
  Fail-closed verifier for residual A2A projection overrides.

  The verifier does not validate a hand-authored capability model. It checks
  only that each optional override points at a real public Ash action; the
  actual capability set is derived from Ash introspection.
  """
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    case Verifier.get_persisted(dsl, :ash_a2a_skill_overrides, nil) do
      nil ->
        {:error,
         Spark.Error.DslError.exception(
           path: [:a2a],
           message: "AshA2A residual override compilation did not complete",
           location: Spark.Dsl.Transformer.get_section_anno(dsl, [:a2a])
         )}

      overrides ->
        case AshA2A.CapabilityIndex.validate(overrides) do
          :ok ->
            with :ok <- verify_consequence_topology(dsl, overrides),
                 :ok <- verify_unique_skill_names(dsl, overrides) do
              warnings = dead_argument_warnings(overrides) ++ inert_section_warnings(dsl)
              if warnings == [], do: :ok, else: {:warn, warnings}
            end

          {:error, refusals} ->
            {:error,
             Spark.Error.DslError.exception(
               path: [:a2a],
               message: Enum.map_join(refusals, "; ", &"#{&1.code}: #{&1.detail}"),
               location: override_location(dsl, overrides)
             )}
        end
    end
  end

  # Every exposed public action of the subject (default-projected create/
  # update/destroy included, not only explicitly declared overrides) with its
  # effective consequence -- the same derivation the capability compiler uses.
  defp exposed_consequences(dsl, overrides) do
    dsl
    |> subject_resources()
    |> Enum.flat_map(fn {resource_key, actions} ->
      Enum.flat_map(actions, fn action ->
        override =
          Enum.find(overrides, fn o ->
            o.action == action.name and (resource_key == :self or o.resource == resource_key)
          end)

        if override && override.expose? == false do
          []
        else
          consequence =
            (override && override.consequence) ||
              AshA2A.CapabilityIndex.Compiler.default_consequence(action.type)

          [%{resource: resource_key, action: action.name, consequence: consequence}]
        end
      end)
    end)
  end

  defp subject_resources(dsl) do
    case Verifier.get_persisted(dsl, :ash_a2a_subject_kind) do
      :resource ->
        [{:self, Ash.Resource.Info.public_actions(dsl)}]

      _ ->
        dsl
        |> Ash.Domain.Info.resources()
        |> Enum.map(&{&1, Ash.Resource.Info.public_actions(&1)})
    end
  end

  defp verify_consequence_topology(dsl, overrides) do
    gate = Spark.Dsl.Transformer.get_option(dsl, [:authority], :gate, :two_port)

    if gate in [:open, :disabled] do
      offenders =
        dsl
        |> exposed_consequences(overrides)
        |> Enum.filter(&(&1.consequence in [:external_do, :change]))

      case offenders do
        [] ->
          :ok

        _ ->
          listing =
            Enum.map_join(offenders, ", ", fn o ->
              "#{inspect(o.action)}#{resource_suffix(o.resource)} (#{inspect(o.consequence)})"
            end)

          {:error,
           Spark.Error.DslError.exception(
             path: [:authority, :gate],
             message:
               "authority gate is #{inspect(gate)} but #{length(offenders)} exposed action(s) " <>
                 "carry a :change/:external_do consequence (default public create/update/" <>
                 "destroy actions included): #{listing}. An external DO or change " <>
                 "consequence requires an active gate.",
             location: Spark.Dsl.Transformer.get_section_anno(dsl, [:authority])
           )}
      end
    else
      :ok
    end
  end

  defp resource_suffix(:self), do: ""
  defp resource_suffix(resource), do: " on #{inspect(resource)}"

  # Domain subjects: an explicitly-named skill (override name differs from the
  # action) that collides with another skill's name across the domain's
  # resources would be a runtime `{:ambiguous_skill, _}`; refuse at compile time.
  defp verify_unique_skill_names(dsl, overrides) do
    if Verifier.get_persisted(dsl, :ash_a2a_subject_kind) == :domain do
      skills =
        dsl
        |> Ash.Domain.Info.resources()
        |> Enum.flat_map(fn resource ->
          resource_overrides =
            case Spark.Dsl.Extension.get_persisted(resource, :ash_a2a_skill_overrides, nil) do
              list when is_list(list) -> list
              _ -> []
            end

          AshA2A.CapabilityIndex.Compiler.compile(
            resource,
            :resource,
            resource_overrides ++ overrides
          )
        end)

      explicit_names =
        skills |> Enum.filter(&(&1.name != &1.action)) |> MapSet.new(& &1.name)

      collisions =
        skills
        |> Enum.group_by(&to_string(&1.name))
        |> Enum.filter(fn {_name, group} ->
          length(group) > 1 and Enum.any?(group, &MapSet.member?(explicit_names, &1.name))
        end)

      case collisions do
        [] ->
          :ok

        _ ->
          detail =
            Enum.map_join(collisions, "; ", fn {name, group} ->
              "#{inspect(name)} -> #{Enum.map_join(group, ", ", & &1.id)}"
            end)

          {:error,
           Spark.Error.DslError.exception(
             path: [:a2a],
             message:
               "ambiguous skill name across resources (would be a runtime ambiguity): #{detail}",
             location: Spark.Dsl.Transformer.get_section_anno(dsl, [:a2a])
           )}
      end
    else
      :ok
    end
  end

  defp override_location(_dsl, [first | _]), do: Spark.Dsl.Entity.anno(first)

  defp override_location(dsl, []) do
    Spark.Dsl.Transformer.get_section_anno(dsl, [:a2a])
  end

  # `AshA2A.Dispatcher` reads `authority gate` (`:disabled` refuses anchored
  # skills) and `hooks` (pre/post dispatch). `:open` gate semantics and
  # `lease_duration_ms` have no enforcing reader, so declaring anything
  # non-default there must not be silently inert: it is surfaced as a
  # compile-time warning.
  defp inert_section_warnings(dsl) do
    lease_ms = Spark.Dsl.Transformer.get_option(dsl, [:authority], :lease_duration_ms, 60_000)
    gate = Spark.Dsl.Transformer.get_option(dsl, [:authority], :gate, :two_port)

    [
      if(gate == :open,
        do:
          "authority gate :open is declared but not enforced at dispatch: only the " <>
            "compile-time consequence topology check reads it (:disabled is enforced by " <>
            "AshA2A.Dispatcher)"
      ),
      if(lease_ms != 60_000,
        do:
          "authority lease_duration_ms #{inspect(lease_ms)} is declared but not enforced: " <>
            "no lease issuer reads AshA2A.Info.lease_duration_ms/1 " <>
            "(needed: AshA2A.Authority broker/dispatcher change)"
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  # `AshA2A.Dsl`'s nested `argument` entity is parsed and persisted onto each
  # `AshA2A.Skill` override's `arguments` field, but real capability
  # compilation (`AshA2A.CapabilityIndex.Compiler.derive_arguments/2`) always
  # derives arguments from the referenced Ash action instead. A declaration
  # there compiles silently and does nothing; surface it as a warning.
  defp dead_argument_warnings(overrides) do
    case Enum.filter(overrides, &(&1.arguments != [])) do
      [] ->
        []

      dead ->
        names = dead |> Enum.map(& &1.name) |> Enum.map_join(", ", &inspect/1)

        [
          "a2a do skill ... do argument ... end end is accepted but ignored by capability " <>
            "compilation -- arguments are always derived from the referenced Ash action, " <>
            "never from this declaration. Remove the argument block(s) on: #{names}."
        ]
    end
  end
end
