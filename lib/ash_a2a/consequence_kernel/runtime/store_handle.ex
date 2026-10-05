# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.Runtime.StoreHandle do
  @moduledoc false
  defstruct [:module, :server]
  def new(module, server), do: %__MODULE__{module: module, server: server}
  def call(%__MODULE__{module: m, server: s}, fun, args), do: apply(m, fun, [s | args])
end
