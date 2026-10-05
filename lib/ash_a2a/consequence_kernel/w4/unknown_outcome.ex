# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.W4.UnknownOutcome do
  @moduledoc false
  def retry?(:unknown_outcome), do: false
  def retry?(_), do: true
  def disposition(:unknown_outcome), do: :reconcile
  def disposition(_), do: :none
end
