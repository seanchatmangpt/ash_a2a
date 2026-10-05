# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.W4.Route do
  @moduledoc false
  @type t :: :observe | :consequence | :refused
  def classify(:observe), do: :observe
  def classify(c) when c in [:change, :external_do], do: :consequence
  def classify(_), do: :refused
end
