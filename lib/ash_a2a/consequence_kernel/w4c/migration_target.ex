# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.W4C.MigrationTarget do
  def for_kind(:observe), do: :dispatch_observe
  def for_kind(_), do: :consequence_kernel
end
