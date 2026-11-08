# SPDX-FileCopyrightText: 2026 ash_a2a contributors
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Authority.Source.DenyAll do
  @moduledoc """
  DEFAULT source: refuses everything, typed. Out of the box the PEP admits
  nothing. Documented loudly per the governance-membrane spec.
  """

  @behaviour AshA2A.Authority.Source

  @impl true
  def check(_actor_id, _action, _context, _opts), do: :deny
end
