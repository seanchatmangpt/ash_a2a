# SPDX-FileCopyrightText: 2026 ash_a2a contributors
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Authority.Source.AllowAll do
  @moduledoc """
  TEST-ONLY source: admits everything. Never configure in production.
  """

  @behaviour AshA2A.Authority.Source

  @impl true
  def check(_actor_id, _action, _context, _opts), do: :ok
end
