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
            dead_argument_warning(overrides)

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

  defp override_location(_dsl, [first | _]), do: Spark.Dsl.Entity.anno(first)

  defp override_location(dsl, []) do
    Spark.Dsl.Transformer.get_section_anno(dsl, [:a2a])
  end

  # `AshA2A.Dsl`'s nested `argument` entity (`a2a do skill ... do argument
  # ... end end`) is parsed and persisted onto each `AshA2A.Skill` override's
  # `arguments` field, but real capability compilation
  # (`AshA2A.CapabilityIndex.Compiler.derive_arguments/2`) always derives
  # arguments from the referenced Ash action's own `arguments`/`accept`
  # instead -- the override struct's `arguments` are never consulted. A
  # declaration there compiles silently and does nothing; this surfaces
  # that as a real Spark compile-time warning instead of a silent no-op.
  defp dead_argument_warning(overrides) do
    case Enum.filter(overrides, &(&1.arguments != [])) do
      [] ->
        :ok

      dead ->
        names = dead |> Enum.map(& &1.name) |> Enum.map_join(", ", &inspect/1)

        {:warn,
         "a2a do skill ... do argument ... end end is accepted but ignored by capability " <>
           "compilation -- arguments are always derived from the referenced Ash action, " <>
           "never from this declaration. Remove the argument block(s) on: #{names}."}
    end
  end
end
