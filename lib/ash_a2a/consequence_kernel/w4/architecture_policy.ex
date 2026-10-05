# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.W4.ArchitecturePolicy do
  @moduledoc false
  @forbidden ["AshA2A.Dispatcher.dispatch(", "Ash.create(", "Ash.update(", "Ash.destroy("]
  def forbidden_tokens, do: @forbidden

  def violations(source) when is_binary(source),
    do: Enum.filter(@forbidden, &String.contains?(source, &1))
end
