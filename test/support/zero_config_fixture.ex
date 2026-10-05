# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

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
    read(:visible)

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
