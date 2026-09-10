defmodule AshA2A.Verify do
  @moduledoc """
  Fail-closed capability verifier, per the PRD/ARD §3.3 "delegate-and-join"
  decision (`~/ggen-marketplace/docs/explanation/ash-a2a-prd-ard.md:166-178`).

  Mirrors `AshR2RML.Resource.Verify`'s exact 2-branch shape
  (`~/ash_r2rml/lib/ash_r2rml/resource.ex:486-512`): the nil-persisted-key
  check stays inline here; the real business check (unique skill names, every
  skill's action actually exists) lives in `AshA2A.CapabilityIndex.validate/1`
  (the Author-phase hand-written module). Refusals are joined the same way
  ash_r2rml joins them: `Enum.map_join(refusals, "; ", &"\#{&1.code}: \#{&1.detail}")`.

  `DSL valid ⇏ Capability valid` -- only `Compile(DSL) = IR ∧ Validate(IR) = PASS`
  admits the capability.
  """
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    case Verifier.get_persisted(dsl, :ash_a2a_capability_index, nil) do
      nil ->
        {:error,
         Spark.Error.DslError.exception(
           path: [:a2a],
           message:
             "AshA2A capability index was not persisted; semantic compilation did not complete",
           location: Spark.Dsl.Transformer.get_section_anno(dsl, [:a2a])
         )}

      index ->
        case AshA2A.CapabilityIndex.validate(index) do
          :ok ->
            :ok

          {:error, refusals} ->
            {:error,
             Spark.Error.DslError.exception(
               path: [:a2a],
               message: Enum.map_join(refusals, "; ", &"#{&1.code}: #{&1.detail}"),
               location: capability_index_location(dsl, index)
             )}
        end
    end
  end

  # Best-effort location for a refusal-join error: refusals are validated
  # across the whole persisted index (duplicate names, missing actions), not
  # against a single entity, so there is no one skill to blame precisely --
  # point at the first compiled skill entity's own annotation (per
  # `Spark.Dsl.Entity.anno/1`, `deps/spark/usage-rules.md` "Error Location
  # Information") rather than emitting no location at all. Falls back to the
  # `:a2a` section's own annotation when the index is empty.
  defp capability_index_location(_dsl, [first_skill | _]) do
    Spark.Dsl.Entity.anno(first_skill)
  end

  defp capability_index_location(dsl, []) do
    Spark.Dsl.Transformer.get_section_anno(dsl, [:a2a])
  end
end
