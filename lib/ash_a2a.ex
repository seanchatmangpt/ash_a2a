defmodule AshA2A do
  @moduledoc """
  Ash extension that projects canonical public Ash actions into A2A skills.

  v26.9.12 is zero-configuration for capability discovery:

      use Ash.Resource, extensions: [AshA2A]

  Every action returned by `Ash.Resource.Info.public_actions/1` is projected
  automatically. An optional `a2a` block only overrides A2A-specific metadata
  or suppresses an otherwise-public action:

      a2a do
        skill :search, :read do
          description "Search the catalog"
          tags ["catalog", "search"]
        end
      end

  Ash remains the source of truth. `skill` declarations cannot create actions,
  change action arguments, or expose `public?: false` actions.
  """

  use Spark.Dsl.Extension,
    sections: AshA2A.Dsl.sections(),
    transformers: [AshA2A.Transformers.BuildCapabilityIndex],
    verifiers: [AshA2A.Verify]
end
