# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.ReplayEvidence do
  def verify(prepared, receipt) do
    cond do
      receipt.effect_id != prepared.instance.effect_id ->
        {:error, :replay_effect_divergence}

      receipt.prepared_digest != prepared.prepared_digest ->
        {:error, :prepared_effect_digest_mismatch}

      true ->
        {:ok, :matched}
    end
  end
end
