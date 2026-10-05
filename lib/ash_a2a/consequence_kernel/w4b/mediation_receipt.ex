# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.W4B.MediationReceipt do
  @moduledoc false
  @enforce_keys [:consequence, :route, :admitted]
  defstruct [:consequence, :route, :admitted, :refusal]
  def admitted(c, route), do: %__MODULE__{consequence: c, route: route, admitted: true}

  def refused(c, route, reason),
    do: %__MODULE__{consequence: c, route: route, admitted: false, refusal: reason}
end
