# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.W5.ReplayEvidence do
  def derive(%{claim_id: c, request_id: r, effect_id: e, prepared_digest: p, subject_digest: s})
      when is_binary(c) and is_binary(r) and is_binary(e) and is_binary(p) and is_binary(s),
      do: %{
        claim_id: c,
        request_id: r,
        effect_id: e,
        prepared_digest: p,
        subject_digest: s,
        authority: :none
      }

  def derive(_), do: {:error, :insufficient_replay_evidence}

  def verify(c, r) when is_map(r) do
    e = derive(c)
    ks = [:claim_id, :request_id, :effect_id, :prepared_digest, :subject_digest]

    if is_map(e) and Map.take(r, ks) == Map.take(e, ks),
      do: :ok,
      else: {:error, :replay_evidence_mismatch}
  end

  def verify(_, _), do: {:error, :replay_evidence_mismatch}
end
