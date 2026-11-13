# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Verifiers.VerifyHddlOperators do
  @moduledoc """
  Compile-time checks for a skill's `hddl_operator` declarations, invoked per
  skill by `AshA2A.Verifiers.VerifySkills` (the extension's verifier list is
  fixed, so this module is a callable check rather than a separate verifier):

    1. at most one `hddl_operator` per skill (an HDDL `:action` is one operator
       per skill) -- `refused_hddl_multiple_operators`;
    2. every fact argument (preconditions, add and delete effects) is one of
       the operator's declared `parameters` -- `refused_hddl_fact_args`.

  Returns a list of `{:error, Spark.Error.DslError.t()}` entries.
  """

  alias Spark.Dsl.Verifier

  @spec check(AshA2A.Skill.t() | map(), map()) :: [{:error, Spark.Error.DslError.t()}]
  def check(skill, dsl_state) do
    case Map.get(skill, :hddl_operators) || [] do
      [] ->
        []

      [operator] ->
        check_facts(skill, operator, dsl_state)

      operators ->
        [
          error(
            skill,
            dsl_state,
            "refused_hddl_multiple_operators: skill #{inspect(skill.name)} declares " <>
              "#{length(operators)} hddl_operator blocks; exactly one operator per skill is allowed"
          )
        ]
    end
  end

  defp check_facts(skill, operator, dsl_state) do
    params = MapSet.new(operator.parameters || [])

    facts =
      Enum.flat_map(
        [:preconditions, :add_effects, :delete_effects],
        fn field -> Enum.map(Map.get(operator, field) || [], &{field, &1}) end
      )

    Enum.flat_map(facts, fn {field, {predicate, args}} ->
      case Enum.reject(args, &MapSet.member?(params, &1)) do
        [] ->
          []

        unknown ->
          [
            error(
              skill,
              dsl_state,
              "refused_hddl_fact_args: skill #{inspect(skill.name)} #{field} fact " <>
                "#{inspect(predicate)} uses #{inspect(unknown)}, which are not declared " <>
                "operator parameters #{inspect(operator.parameters)}"
            )
          ]
      end
    end)
  end

  defp error(skill, dsl_state, message) do
    {:error,
     Spark.Error.DslError.exception(
       module: Verifier.get_persisted(dsl_state, :module),
       path: [:a2a, skill.name, :hddl_operator],
       message: message,
       location: Spark.Dsl.Entity.anno(skill)
     )}
  end
end
