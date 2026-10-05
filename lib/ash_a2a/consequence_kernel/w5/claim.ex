# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.W5.Claim do
  @enforce_keys [:request_id, :effect_id, :prepared_digest, :subject_digest, :claim_id]
  defstruct @enforce_keys
  def new(attrs), do: struct!(__MODULE__, attrs)
end
