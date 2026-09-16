defmodule AshA2A.Test.SA2AConsequenceFixture.Ledger do
  @moduledoc """
  Real `Ash.Resource` fronting `AshA2A.Semantic.Peer`'s S76 consequence
  classification in `test/ash_a2a/semantic_peer_consequence_source_test.exs`.

  It carries one genuinely non-consequence-bearing capability (`:read`, which
  `AshA2A.Skill` classifies `:observe`) and one genuinely
  consequence-bearing one (`:create`, classified `:change`), so the test can
  show that `Peer.consequence_bearing?/2` really tracks the resource's own
  DSL rather than anything the counterparty wrote on the wire. A
  single-shaped surface would make both answers indistinguishable.
  """

  use Ash.Resource,
    domain: AshA2A.Test.SA2AConsequenceFixture.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:entry, :string, public?: true)
  end

  actions do
    defaults([:read, create: [:entry]])
  end

  a2a do
    skill(:read_entries, :read)
    skill(:post_entry, :create)
  end
end

defmodule AshA2A.Test.SA2AConsequenceFixture.Domain do
  @moduledoc "Real domain giving `Ledger` a compiled `AshA2A` capability index."

  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2A.Test.SA2AConsequenceFixture.Ledger)
  end
end

defmodule AshA2A.Test.SA2AConsequenceFixture.ObserveOnly do
  @moduledoc """
  Real `Ash.Resource` with exactly one capability, and that capability
  non-consequence-bearing.

  Exercises `Peer.consequence_bearing?/2`'s sole-capability branch: a message
  that names no skill against a surface with one `:observe` capability is
  genuinely not asking for a consequence.
  """

  use Ash.Resource,
    domain: AshA2A.Test.SA2AConsequenceFixture.ObserveOnlyDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])
  end

  a2a do
    skill(:read_only, :read)
  end
end

defmodule AshA2A.Test.SA2AConsequenceFixture.ObserveOnlyDomain do
  @moduledoc "Real domain for `ObserveOnly`."

  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2A.Test.SA2AConsequenceFixture.ObserveOnly)
  end
end
