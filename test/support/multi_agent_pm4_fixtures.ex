# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.MultiAgentPm4Test.IntakeResource do
  use Ash.Resource,
    domain: AshA2A.MultiAgentPm4Test.IntakeDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])
  end

  a2a do
    skill(:work, :read)
  end
end

defmodule AshA2A.MultiAgentPm4Test.IntakeDomain do
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.MultiAgentPm4Test.IntakeResource)
  end
end

defmodule AshA2A.MultiAgentPm4Test.IntakeAgent do
  use AshA2A.Agent,
    resource_or_domain: AshA2A.MultiAgentPm4Test.IntakeResource,
    name: "multi_agent_pm4_intake"
end

defmodule AshA2A.MultiAgentPm4Test.ReviewResource do
  use Ash.Resource,
    domain: AshA2A.MultiAgentPm4Test.ReviewDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])
  end

  a2a do
    skill(:work, :read)
  end
end

defmodule AshA2A.MultiAgentPm4Test.ReviewDomain do
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.MultiAgentPm4Test.ReviewResource)
  end
end

defmodule AshA2A.MultiAgentPm4Test.ReviewAgent do
  use AshA2A.Agent,
    resource_or_domain: AshA2A.MultiAgentPm4Test.ReviewResource,
    name: "multi_agent_pm4_review"
end

defmodule AshA2A.MultiAgentPm4Test.FulfilResource do
  use Ash.Resource,
    domain: AshA2A.MultiAgentPm4Test.FulfilDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])
  end

  a2a do
    skill(:work, :read)
  end
end

defmodule AshA2A.MultiAgentPm4Test.FulfilDomain do
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.MultiAgentPm4Test.FulfilResource)
  end
end

defmodule AshA2A.MultiAgentPm4Test.FulfilAgent do
  use AshA2A.Agent,
    resource_or_domain: AshA2A.MultiAgentPm4Test.FulfilResource,
    name: "multi_agent_pm4_fulfil"
end
