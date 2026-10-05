# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.EvidenceRef do
  @moduledoc """
  Portable reference to authority-free semantic evidence.

  SA2A does not reinterpret RDF or run a second semantic engine here. This module
  admits the already-verifiable evidence reference produced by AshR2RML/Kudzu/
  ggen_igniter, and preserves it inside PreparedEffect identity. Evidence can
  constrain or explain construction; it cannot authorize DO.
  """

  @schema "sa2a.semantic-evidence-envelope.v1"
  @contract_version "v26.9.29"
  @digest_pattern ~r/\Asha256:[0-9a-f]{64}\z/

  @required ~w(schema contractVersion subject sourceDigest graphDigest replayIdentity envelopeDigest authority consequence)

  @type t :: %{
          required(String.t()) => term()
        }

  @spec admit_optional(nil | map()) :: {:ok, nil | map()} | {:error, map()}
  def admit_optional(nil), do: {:ok, nil}
  def admit_optional(ref), do: admit(ref)

  @spec admit(map()) :: {:ok, map()} | {:error, map()}
  def admit(ref) when is_map(ref) do
    missing = Enum.reject(@required, &Map.has_key?(ref, &1))

    cond do
      missing != [] ->
        refuse(:shape, %{missing: missing})

      ref["schema"] != @schema ->
        refuse(:schema, %{observed: ref["schema"]})

      ref["contractVersion"] != @contract_version ->
        refuse(:contract_version, %{observed: ref["contractVersion"]})

      ref["authority"] != "NONE" ->
        refuse(:authority, %{observed: ref["authority"]})

      ref["consequence"] != "EVIDENCE_ONLY" ->
        refuse(:consequence, %{observed: ref["consequence"]})

      not non_empty?(ref["subject"]) ->
        refuse(:subject, %{observed: ref["subject"]})

      not digest?(ref["sourceDigest"]) ->
        refuse(:source_digest, %{observed: ref["sourceDigest"]})

      not digest?(ref["graphDigest"]) ->
        refuse(:graph_digest, %{observed: ref["graphDigest"]})

      not non_empty?(ref["replayIdentity"]) ->
        refuse(:replay_identity, %{observed: ref["replayIdentity"]})

      not digest?(ref["envelopeDigest"]) ->
        refuse(:envelope_digest, %{observed: ref["envelopeDigest"]})

      true ->
        {:ok, Map.take(ref, @required)}
    end
  end

  def admit(other), do: refuse(:shape, %{observed: inspect(other)})

  @doc "Stable portable identity of the admitted evidence reference itself."
  @spec digest(map()) :: {:ok, String.t()} | {:error, map()}
  def digest(ref) do
    with {:ok, admitted} <- admit(ref) do
      AshA2A.Identity.Canonical.digest(admitted)
    end
  end

  defp digest?(value), do: is_binary(value) and Regex.match?(@digest_pattern, value)
  defp non_empty?(value), do: is_binary(value) and String.trim(value) != ""

  defp refuse(subject, evidence),
    do: {:error, %{code: :refused_semantic_evidence, subject: subject, evidence: evidence}}
end
