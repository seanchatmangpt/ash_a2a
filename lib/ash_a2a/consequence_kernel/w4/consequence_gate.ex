# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.W4.ConsequenceGate do
  @moduledoc false
  alias AshA2A.ConsequenceKernel.W4.Route

  def admit(c) do
    case Route.classify(c) do
      :consequence -> :ok
      :observe -> {:error, :not_consequential}
      :refused -> {:error, :consequence_unclassified}
    end
  end
end
