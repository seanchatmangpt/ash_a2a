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
            :ok

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
end
