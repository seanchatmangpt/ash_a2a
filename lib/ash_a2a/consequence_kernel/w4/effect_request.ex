# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.W4.EffectRequest do
  @moduledoc false
  @enforce_keys [:skill, :message, :resource_or_domain, :consequence]
  defstruct [:skill, :message, :resource_or_domain, :consequence, history: [], auth_identity: nil]
  @type t :: %__MODULE__{}
end
