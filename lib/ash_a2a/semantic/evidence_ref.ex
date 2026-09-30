defmodule AshA2A.Semantic.EvidenceRef do
  @moduledoc """
  Portable reference to authority-free semantic evidence.

  SA2A does not reinterpret RDF or run a second semantic engine here. This module
  admits already-verifiable evidence produced by GraphLaw/AshR2RML/Kudzu/
  ggen_igniter and preserves it inside PreparedEffect identity. Evidence can
  constrain or explain construction; it cannot authorize DO.

  Two v26.9.29 producer shapes are accepted:

    * the original flat reference with `sourceDigest`;
    * the exact-source AshR2RML envelope with nested `source`,
      `canonicalization`, provenance, and a replayable `envelopeDigest`.

  Exact-source envelopes are admitted fail-closed: source identity is complete,
  authority is `NONE`, consequence is `EVIDENCE_ONLY`, canonicalization is
  `RDFC-1.0`, and the envelope digest must recompute under AshR2RML's
  versioned canonical-JSON digest domain.
  """

  @schema "sa2a.semantic-evidence-envelope.v1"
  @contract_version "v26.9.29"
  @canonicalization "RDFC-1.0"
  @ash_r2rml_digest_domain "ashr2rml.vkg.canonical.v1\n"
  @digest_pattern ~r/\Asha256:[0-9a-f]{64}\z/

  @flat_required ~w(schema contractVersion subject sourceDigest graphDigest replayIdentity envelopeDigest authority consequence)
  @flat_optional ~w(canonicalization provenance)
  @exact_required ~w(schema contractVersion canonicalization authority consequence subject source graphDigest replayIdentity provenance envelopeDigest)
  @exact_optional ~w(receiptDigest)
  @source_required ~w(id uri graph subjectTemplate digest)
  @source_optional ~w(version)

  @type t :: %{required(String.t()) => term()}

  @spec admit_optional(nil | map()) :: {:ok, nil | map()} | {:error, map()}
  def admit_optional(nil), do: {:ok, nil}
  def admit_optional(ref), do: admit(ref)

  @spec admit(map()) :: {:ok, map()} | {:error, map()}
  def admit(ref) when is_map(ref) do
    if Map.has_key?(ref, "source"), do: admit_exact_source(ref), else: admit_flat(ref)
  end

  def admit(other), do: refuse(:shape, %{observed: inspect(other)})

  @doc "Stable portable identity of the admitted evidence reference itself."
  @spec digest(map()) :: {:ok, String.t()} | {:error, map()}
  def digest(ref) do
    with {:ok, admitted} <- admit(ref) do
      AshA2A.Identity.Canonical.digest(admitted)
    end
  end

  defp admit_flat(ref) do
    missing = Enum.reject(@flat_required, &Map.has_key?(ref, &1))

    cond do
      missing != [] ->
        refuse(:shape, %{missing: missing})

      ref["schema"] != @schema ->
        refuse(:schema, %{observed: ref["schema"]})

      ref["contractVersion"] != @contract_version ->
        refuse(:contract_version, %{observed: ref["contractVersion"]})

      Map.has_key?(ref, "canonicalization") and ref["canonicalization"] != @canonicalization ->
        refuse(:canonicalization, %{observed: ref["canonicalization"]})

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
        {:ok, Map.take(ref, @flat_required ++ @flat_optional)}
    end
  end

  defp admit_exact_source(ref) do
    missing = Enum.reject(@exact_required, &Map.has_key?(ref, &1))
    unknown = Map.keys(ref) -- (@exact_required ++ @exact_optional)

    cond do
      missing != [] ->
        refuse(:shape, %{missing: missing})

      unknown != [] ->
        refuse(:shape, %{unknown: Enum.sort(unknown)})

      ref["schema"] != @schema ->
        refuse(:schema, %{observed: ref["schema"]})

      ref["contractVersion"] != @contract_version ->
        refuse(:contract_version, %{observed: ref["contractVersion"]})

      ref["canonicalization"] != @canonicalization ->
        refuse(:canonicalization, %{observed: ref["canonicalization"]})

      ref["authority"] != "NONE" ->
        refuse(:authority, %{observed: ref["authority"]})

      ref["consequence"] != "EVIDENCE_ONLY" ->
        refuse(:consequence, %{observed: ref["consequence"]})

      not non_empty?(ref["subject"]) ->
        refuse(:subject, %{observed: ref["subject"]})

      not valid_source?(ref["source"]) ->
        refuse(:source, %{observed: ref["source"]})

      not digest?(ref["graphDigest"]) ->
        refuse(:graph_digest, %{observed: ref["graphDigest"]})

      not non_empty?(ref["replayIdentity"]) ->
        refuse(:replay_identity, %{observed: ref["replayIdentity"]})

      not is_map(ref["provenance"]) ->
        refuse(:provenance, %{observed: inspect(ref["provenance"])})

      not optional_digest?(ref["receiptDigest"]) ->
        refuse(:receipt_digest, %{observed: ref["receiptDigest"]})

      not digest?(ref["envelopeDigest"]) ->
        refuse(:envelope_digest, %{observed: ref["envelopeDigest"]})

      not envelope_digest_valid?(ref) ->
        refuse(:envelope_digest, %{observed: ref["envelopeDigest"], reason: :replay_mismatch})

      true ->
        {:ok, Map.take(ref, @exact_required ++ @exact_optional)}
    end
  end

  defp valid_source?(source) when is_map(source) do
    missing = Enum.reject(@source_required, &Map.has_key?(source, &1))
    unknown = Map.keys(source) -- (@source_required ++ @source_optional)

    missing == [] and unknown == [] and
      Enum.all?(~w(id uri graph subjectTemplate), &non_empty?(source[&1])) and
      digest?(source["digest"]) and
      (is_nil(source["version"]) or is_binary(source["version"]))
  end

  defp valid_source?(_), do: false

  defp envelope_digest_valid?(ref) do
    body = Map.delete(ref, "envelopeDigest")

    expected =
      if Code.ensure_loaded?(AshR2RML.VKG.Serializer) and
           function_exported?(AshR2RML.VKG.Serializer, :digest, 1) do
        "sha256:" <> apply(AshR2RML.VKG.Serializer, :digest, [body])
      else
        fallback_ash_r2rml_digest(body)
      end

    expected == ref["envelopeDigest"]
  end

  defp fallback_ash_r2rml_digest(body) do
    with {:ok, canonical} <- AshA2A.Identity.Canonical.encode(body) do
      "sha256:" <>
        (:crypto.hash(:sha256, [@ash_r2rml_digest_domain, canonical])
         |> Base.encode16(case: :lower))
    else
      {:error, _reason} -> nil
    end
  end

  defp optional_digest?(nil), do: true
  defp optional_digest?(value), do: digest?(value)

  defp digest?(value), do: is_binary(value) and Regex.match?(@digest_pattern, value)
  defp non_empty?(value), do: is_binary(value) and String.trim(value) != ""

  defp refuse(subject, evidence),
    do: {:error, %{code: :refused_semantic_evidence, subject: subject, evidence: evidence}}
end
