# SPDX-FileCopyrightText: 2026 ash_a2a contributors
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Authority.Source.AllowAll do
  @moduledoc """
  TEST-ONLY source: admits everything. Never configure in production.
  """

  @behaviour AshA2A.Authority.Source

  @env Mix.env()

  @impl true
  def check(actor_id, action, context, opts),
    do: __check__(env(), actor_id, action, context, opts)

  # Compile-time env OR a runtime release marker (RELEASE_NAME is set by mix releases).
  defp env do
    if @env == :prod or System.get_env("RELEASE_NAME") != nil, do: :prod, else: @env
  end

  @doc false
  def __check__(:prod, _actor_id, _action, _context, _opts), do: {:deny, :allow_all_in_prod}
  def __check__(_env, _actor_id, _action, _context, _opts), do: :ok
end
