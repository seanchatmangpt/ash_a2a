# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.W4B.BypassClassification do
  @moduledoc false
  def classify(:observe), do: :non_consequential
  def classify(c) when c in [:change, :external_do], do: :consequential
  def classify(_), do: :unclassified
end
