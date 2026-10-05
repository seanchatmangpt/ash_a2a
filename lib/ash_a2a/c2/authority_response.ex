# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C2.AuthorityResponse do
  @enforce_keys [:decision]
  defstruct [:decision, :certificate, :reason]
  def admit(c), do: %__MODULE__{decision: :admit, certificate: c}
  def refuse(r), do: %__MODULE__{decision: :refuse, reason: r}
end
