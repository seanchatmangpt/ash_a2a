# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.W4C.GraphEdge do
  @enforce_keys [:caller, :callee, :kind]
  defstruct [:caller, :callee, :kind, :source]
  def consequential?(%__MODULE__{kind: k}), do: k in [:effect, :dynamic_effect, :dispatcher]
end
