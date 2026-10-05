# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.RefusalRegistry do
  @moduledoc false
  alias AshA2A.ConsequenceKernel.RefusalCodes
  def known?(c), do: RefusalCodes.known?(c)
  def codes, do: RefusalCodes.codes()
  def classify(c), do: RefusalCodes.classify(c)
end
