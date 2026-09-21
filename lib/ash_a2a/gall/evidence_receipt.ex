defmodule AshA2A.Gall.EvidenceReceipt do
  @moduledoc """
  The `gall:EvidenceReceipt` transport message (PRD §43.5): the typed
  shape that carries a receipt's identity and its reported standing across
  the A2A boundary.

  Fields:

    * `type` -- always `"gall:EvidenceReceipt"`.
    * `receipt_id` -- the receipt identity.
    * `checkpoint_iri` -- the checkpoint the receipt is about.
    * `checkpoint_digest` -- the typed `sha256:...` checkpoint digest.
    * `candidate_sha` -- the 40-hex candidate head SHA.
    * `verifier_id` -- the verifier that produced the outcome.
    * `verified_outcome` -- the verifier's reported outcome.
    * `standing` -- the standing vocabulary, exactly
      `UNKNOWN | PARTIAL_ALIVE | ALIVE | BLOCKED | BUILD_BROKEN |
      UNSUPPORTED`.

  ## The standing is a report, not a grant

  Transporting this message does not make the reported standing true at
  the receiving runtime, and does not grant the receiver anything the
  receipt describes. Standing is evidence *held where it was earned*
  (`ALIVE` requires observed execution there); what crosses the boundary
  here is a typed report of it. An unknown standing string is a
  `{:refused, "REFUSED_STRUCTURE"}` refusal -- the vocabulary is closed,
  never `String.to_atom/1`-ed open.
  """

  alias AshA2A.Gall.Fields

  @type_string "gall:EvidenceReceipt"

  @standing ["UNKNOWN", "PARTIAL_ALIVE", "ALIVE", "BLOCKED", "BUILD_BROKEN", "UNSUPPORTED"]

  @enforce_keys [
    :type,
    :receipt_id,
    :checkpoint_iri,
    :checkpoint_digest,
    :candidate_sha,
    :verifier_id,
    :verified_outcome,
    :standing
  ]

  defstruct [
    :type,
    :receipt_id,
    :checkpoint_iri,
    :checkpoint_digest,
    :candidate_sha,
    :verifier_id,
    :verified_outcome,
    :standing
  ]

  @type t :: %__MODULE__{
          type: String.t(),
          receipt_id: String.t(),
          checkpoint_iri: String.t(),
          checkpoint_digest: String.t(),
          candidate_sha: String.t(),
          verifier_id: String.t(),
          verified_outcome: String.t(),
          standing: String.t()
        }

  @doc "The message type literal this struct always carries."
  @spec type() :: String.t()
  def type, do: @type_string

  @doc "The closed standing vocabulary, exactly."
  @spec standing_values() :: [String.t()]
  def standing_values, do: @standing

  @doc """
  Builds and validates an evidence-receipt message from an atom- or
  string-keyed map (or keyword list). `type` defaults to
  `"gall:EvidenceReceipt"` when absent and is refused when present with
  any other value.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:refused, String.t()}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    case Fields.fetch(attrs, :type, "type") do
      t when t in [nil, @type_string] ->
        build(attrs)

      _other ->
        {:refused, "REFUSED_STRUCTURE"}
    end
  end

  def new(_other), do: {:refused, "REFUSED_STRUCTURE"}

  defp build(attrs) do
    receipt_id = Fields.fetch(attrs, :receipt_id, "receiptId")
    checkpoint_iri = Fields.fetch(attrs, :checkpoint_iri, "checkpointIri")
    checkpoint_digest = Fields.fetch(attrs, :checkpoint_digest, "checkpointDigest")
    candidate_sha = Fields.fetch(attrs, :candidate_sha, "candidateSha")
    verifier_id = Fields.fetch(attrs, :verifier_id, "verifierId")
    verified_outcome = Fields.fetch(attrs, :verified_outcome, "verifiedOutcome")
    standing = Fields.fetch(attrs, :standing, "standing")

    cond do
      not Fields.non_empty_binary?(receipt_id) ->
        {:refused, "REFUSED_STRUCTURE"}

      not Fields.iri?(checkpoint_iri) ->
        {:refused, "REFUSED_STRUCTURE"}

      not Fields.sha256_digest?(checkpoint_digest) ->
        {:refused, "REFUSED_STRUCTURE"}

      not Fields.hex40?(candidate_sha) ->
        {:refused, "REFUSED_STRUCTURE"}

      not Fields.non_empty_binary?(verifier_id) ->
        {:refused, "REFUSED_STRUCTURE"}

      not Fields.non_empty_binary?(verified_outcome) ->
        {:refused, "REFUSED_STRUCTURE"}

      standing not in @standing ->
        {:refused, "REFUSED_STRUCTURE"}

      true ->
        {:ok,
         %__MODULE__{
           type: @type_string,
           receipt_id: receipt_id,
           checkpoint_iri: checkpoint_iri,
           checkpoint_digest: checkpoint_digest,
           candidate_sha: candidate_sha,
           verifier_id: verifier_id,
           verified_outcome: verified_outcome,
           standing: standing
         }}
    end
  end

  @doc """
  Parses from a JSON binary or an already-decoded map.
  """
  @spec from_json(String.t() | map()) :: {:ok, t()} | {:refused, String.t()}
  def from_json(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} when is_map(decoded) -> from_json(decoded)
      _other -> {:refused, "REFUSED_STRUCTURE"}
    end
  end

  def from_json(payload) when is_map(payload), do: new(payload)
  def from_json(_other), do: {:refused, "REFUSED_STRUCTURE"}

  @doc "Serializes to the wire-shaped map (camelCase keys)."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = message) do
    %{
      "type" => message.type,
      "receiptId" => message.receipt_id,
      "checkpointIri" => message.checkpoint_iri,
      "checkpointDigest" => message.checkpoint_digest,
      "candidateSha" => message.candidate_sha,
      "verifierId" => message.verifier_id,
      "verifiedOutcome" => message.verified_outcome,
      "standing" => message.standing
    }
  end

  @doc "Serializes to a JSON binary via `Jason`."
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = message), do: message |> to_map() |> Jason.encode!()
end
