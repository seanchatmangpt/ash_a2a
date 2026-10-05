# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.UnknownOutcome do
  @enforce_keys [:effect_id, :prepared_digest, :reason]
  defstruct [:effect_id, :prepared_digest, :reason, :evidence]

  @type t :: %__MODULE__{
          effect_id: binary(),
          prepared_digest: binary(),
          reason: term(),
          evidence: list()
        }

  def new(prepared, reason, evidence \\ []) do
    %__MODULE__{
      effect_id: prepared.instance.effect_id,
      prepared_digest: prepared.prepared_digest,
      reason: reason,
      evidence: evidence
    }
  end
end
