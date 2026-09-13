defmodule AshA2A.Test.Fixture.ZeroConfig do
  @moduledoc false

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.ZeroConfigDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    read :visible

    read :internal do
      public?(false)
    end
  end
end

defmodule AshA2A.Test.Fixture.ZeroConfigDomain do
  @moduledoc false

  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2A.Test.Fixture.ZeroConfig)
  end
end
