# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.CommandBinding do
  @moduledoc "Binds a candidate to the exact command capability and candidate digest."

  def admit(candidate, command) when is_map(candidate) and is_map(command) do
    capability = AshA2A.Gall.Fields.get(candidate, :capability_id)
    digest = AshA2A.Gall.Fields.get(candidate, :candidate_digest)
    command_capability = AshA2A.Gall.Fields.get(command, :capability_id)
    metadata = AshA2A.Gall.Fields.get(command, :metadata) || %{}

    bound =
      AshA2A.Gall.Fields.get(metadata, :gall_029_candidate_digest) ||
        AshA2A.Gall.Fields.get(metadata, :candidate_digest)

    cond do
      command_capability != capability ->
        {:error, {:refused_gall, :command_binding, :capability_mismatch}}

      bound != digest ->
        {:error, {:refused_gall, :command_binding, :candidate_digest_mismatch}}

      true ->
        {:ok, command}
    end
  end

  def admit(_, _), do: {:error, {:refused_gall, :command_binding, :invalid_command}}
end
