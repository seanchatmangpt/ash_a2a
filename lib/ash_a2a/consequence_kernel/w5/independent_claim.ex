# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.W5.IndependentClaim do
  def admit(r, e) when is_binary(r) and is_binary(e) and r != e, do: :ok
  def admit(_, _), do: {:error, :independent_effect_claim_required}
end
