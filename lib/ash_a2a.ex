defmodule AshA2A do
  @moduledoc """
  Ash extension exposing resource/domain actions as A2A-discoverable agent
  skills. `use Ash.Resource, extensions: [AshA2A]` (or `use Ash.Domain,
  extensions: [AshA2A]`), then declare:

      a2a do
        skill :echo, :read
      end

  Per the ash_a2a PRD/ARD §3.2, `AshA2A.Info.agent_card/1` builds the
  advertised `A2A.AgentCard` exclusively from the persisted, verified
  `:ash_a2a_capability_index` this extension's transformer builds -- never
  from raw DSL entities directly.

  `AshA2A.Transformers.BuildCapabilityIndex` is the sole transformer that
  compiles and persists `:ash_a2a_capability_index` (a bare list of
  `AshA2A.CapabilityIndex.skill()` maps -- the exact shape
  `AshA2A.CapabilityIndex.validate/1`, `AshA2A.Info.capability_index_result/1`,
  and `AshA2A.CapabilityIndex.build_agent_card/2` all require via their
  `is_list/1` guards). `AshA2A.Verify` runs after it as a `Spark.Dsl.Verifier`
  and is the fail-closed business-check gate (ash_a2a PRD/ARD §3.3): `DSL
  valid ⇏ Capability valid`, mirroring `AshR2RML`'s
  one-transformer-builds/one-verifier-validates split
  (`~/ash_r2rml/lib/ash_r2rml/resource.ex:162-167`).
  """

  use Spark.Dsl.Extension,
    sections: AshA2A.Dsl.sections(),
    transformers: [AshA2A.Transformers.BuildCapabilityIndex],
    verifiers: [AshA2A.Verify]
end
