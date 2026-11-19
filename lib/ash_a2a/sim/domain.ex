# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# Compiled only when Bandit is available, like the rest of the simulation
# server (see AshA2A.Sim.Server).
if Code.ensure_loaded?(Bandit) do
  defmodule AshA2A.Sim.Domain do
    @moduledoc """
    The Ash domain behind the simulation server. It holds `AshA2A.Sim.Note`,
    the one resource whose public actions `AshA2A.Sim.Agent` serves as skills.
    """

    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshA2A.Sim.Note
    end
  end
end
