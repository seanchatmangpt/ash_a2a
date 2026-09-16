defmodule AshA2A.Chicago.Fixtures.OcelValidator.Record do
  @moduledoc """
  Real Ash resource the `SA2A-OCEL` court drives through the real
  `AshA2A.CommandBus` to manufacture genuine observer-produced OCEL evidence
  (RFC-SA2A-002 §15). The court submits a `:change` command without authority,
  so the bus resolves the target and refuses admission before any receipt is
  claimed or any row is written -- the evidence is real SUT process history,
  not a hand-written log.
  """

  use Ash.Resource,
    domain: AshA2A.Chicago.Fixtures.OcelValidator.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:label, :string, public?: true, allow_nil?: false)
  end

  actions do
    defaults([:read, create: [:label]])
  end

  a2a do
    skill(:create_record, :create)
  end
end

defmodule AshA2A.Chicago.Fixtures.OcelValidator.Domain do
  @moduledoc "Domain for `AshA2A.Chicago.Fixtures.OcelValidator.Record`."

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.Chicago.Fixtures.OcelValidator.Record)
  end
end
