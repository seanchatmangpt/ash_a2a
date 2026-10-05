# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.EvidencePolicy do
  @moduledoc "Preserves evidence class and binds evidence to an admitted digest set."

  @digest ~r/\Asha256:[0-9a-f]{64}\z/
  @classes ~w(conformance prediction attribution postcondition)

  def admit(candidate, allowed_digests) when is_map(candidate) and is_list(allowed_digests) do
    digest = AshA2A.Gall.Fields.get(candidate, :evidence_digest)
    class = AshA2A.Gall.Fields.get(candidate, :finding_class)

    cond do
      not is_binary(digest) or not Regex.match?(@digest, digest) ->
        {:error, {:refused_gall, :evidence_policy, :invalid_digest}}

      digest not in allowed_digests ->
        {:error, {:refused_gall, :evidence_policy, :unadmitted_evidence}}

      class not in @classes ->
        {:error, {:refused_gall, :evidence_policy, {:unsupported_class, class}}}

      true ->
        {:ok, candidate}
    end
  end

  def admit(_, _), do: {:error, {:refused_gall, :evidence_policy, :invalid_policy}}
end
