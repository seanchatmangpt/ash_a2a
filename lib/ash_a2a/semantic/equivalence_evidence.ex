defmodule AshA2A.Semantic.EquivalenceEvidence do
  @moduledoc """
  Bounded evidence that two independently identified interchange projections
  satisfy the same semantic contract under one exact court.

  Equivalence is evidence, never identity, standing, authority, or permission
  to execute. Different artifacts/runtimes retain distinct portable identities.
  """
  alias AshA2A.Semantic.InterchangeContract

  @enforce_keys [:left_identity, :right_identity, :court, :observation_digest,
    :falsifier_digest, :portable_identity]
  defstruct [:left_identity, :right_identity, :court, :observation_digest,
    :falsifier_digest, :portable_identity,
    technical_standing: "CANDIDATE", external_standing: "NONE", runtime_authority: "NONE"]

  @digest ~r/\A(?:sha256|blake3):[0-9a-f]{64}\z/

  def new(%InterchangeContract{} = left, %InterchangeContract{} = right, attrs)
      when is_map(attrs) do
    with :ok <- InterchangeContract.verify(left),
         :ok <- InterchangeContract.verify(right),
         :ok <- same_semantics(left, right),
         :ok <- distinct_projection(left, right),
         {:ok, court} <- text(attrs, :court),
         {:ok, observations} <- digest(attrs, :observation_digest),
         {:ok, falsifiers} <- digest(attrs, :falsifier_digest),
         :ok <- none(attrs, :external_standing),
         :ok <- none(attrs, :runtime_authority) do
      payload = %{
        "schema" => "ash-a2a.semantic-equivalence/v1",
        "left_identity" => left.portable_identity,
        "right_identity" => right.portable_identity,
        "court" => court,
        "observation_digest" => observations,
        "falsifier_digest" => falsifiers,
        "technical_standing" => "CANDIDATE",
        "external_standing" => "NONE",
        "runtime_authority" => "NONE"
      }

      {:ok, struct!(__MODULE__,
        left_identity: left.portable_identity,
        right_identity: right.portable_identity,
        court: court,
        observation_digest: observations,
        falsifier_digest: falsifiers,
        portable_identity: portable(payload))}
    end
  end

  def new(_, _, _), do: {:error, :semantic_equivalence_invalid_input}

  def verify(%__MODULE__{} = evidence, %InterchangeContract{} = left,
      %InterchangeContract{} = right) do
    attrs = %{court: evidence.court, observation_digest: evidence.observation_digest,
      falsifier_digest: evidence.falsifier_digest,
      external_standing: evidence.external_standing,
      runtime_authority: evidence.runtime_authority}

    with {:ok, rebuilt} <- new(left, right, attrs),
         true <- rebuilt.portable_identity == evidence.portable_identity ||
           {:error, :semantic_equivalence_identity_mismatch},
         true <- evidence.technical_standing == "CANDIDATE" ||
           {:error, :semantic_equivalence_self_declared_standing} do
      :ok
    end
  end

  def verify(_, _, _), do: {:error, :semantic_equivalence_invalid_input}

  defp same_semantics(left, right) do
    if left.semantic_vocabulary == right.semantic_vocabulary and
         left.interface_digest == right.interface_digest do
      :ok
    else
      {:error, :semantic_equivalence_contract_mismatch}
    end
  end

  defp distinct_projection(left, right) do
    if left.portable_identity != right.portable_identity do
      :ok
    else
      {:error, :semantic_equivalence_distinct_projection_required}
    end
  end

  defp text(attrs, key), do: case Map.get(attrs, key) do
    v when is_binary(v) and byte_size(v) > 0 -> {:ok, v}
    _ -> {:error, {:semantic_equivalence_field_required, key}}
  end

  defp digest(attrs, key) do
    with {:ok, v} <- text(attrs, key),
         true <- Regex.match?(@digest, v) ||
           {:error, {:semantic_equivalence_digest_required, key}}, do: {:ok, v}
  end

  defp none(attrs, key),
    do: if(Map.get(attrs, key, "NONE") == "NONE", do: :ok,
      else: {:error, {:semantic_equivalence_authority_ceiling, key}})

  defp portable(payload),
    do: "sha256:" <> (:crypto.hash(:sha256, Jcs.encode(payload)) |> Base.encode16(case: :lower))
end
