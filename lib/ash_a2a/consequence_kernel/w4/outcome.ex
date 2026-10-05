# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.W4.Outcome do
  @moduledoc false
  def classify({:ok, _}), do: :completed
  def classify({:error, %{outcome_known?: false}}), do: :unknown_outcome
  def classify({:error, _}), do: :failed
  def classify(_), do: :unknown_outcome
end
