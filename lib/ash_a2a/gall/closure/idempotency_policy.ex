# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.IdempotencyPolicy do
  @moduledoc "Requires a stable idempotency key bound to the exact candidate identity."

  alias AshA2A.Gall.Closure.Determinism

  def admit(command, candidate) when is_map(command) and is_map(candidate) do
    metadata = AshA2A.Gall.Fields.get(command, :metadata) || %{}
    key = AshA2A.Gall.Fields.get(metadata, :idempotency_key)
    candidate_digest = AshA2A.Gall.Fields.get(candidate, :candidate_digest)

    cond do
      not is_binary(candidate_digest) ->
        {:error, {:refused_gall, :idempotency_policy, :missing_candidate_digest}}

      not is_binary(key) or key == "" ->
        {:error, {:refused_gall, :idempotency_policy, :idempotency_key_required}}

      key != key_for(candidate_digest) ->
        {:error,
         {:refused_gall, :idempotency_policy, {:key_mismatch, key_for(candidate_digest), key}}}

      true ->
        {:ok, command}
    end
  end

  def admit(_, _), do: {:error, {:refused_gall, :idempotency_policy, :invalid_command}}

  def key_for(candidate_digest) when is_binary(candidate_digest),
    do: "gall:" <> Determinism.digest(candidate_digest)
end
