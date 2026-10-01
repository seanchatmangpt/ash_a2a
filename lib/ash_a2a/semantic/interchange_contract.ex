defmodule AshA2A.Semantic.InterchangeContract do
  @moduledoc "Evidence-only identity for a semantic interchangeable implementation."
  @enforce_keys [:source_repository, :source_revision, :semantic_vocabulary,
    :interface_digest, :projection_rule, :target_runtime, :artifact_digest, :portable_identity]
  defstruct [:source_repository, :source_revision, :semantic_vocabulary,
    :interface_digest, :projection_rule, :target_runtime, :artifact_digest, :portable_identity,
    technical_standing: "CANDIDATE", external_standing: "NONE", runtime_authority: "NONE"]

  @sha40 ~r/\A[0-9a-f]{40}\z/
  @digest ~r/\A(?:sha256|blake3):[0-9a-f]{64}\z/

  def new(attrs) when is_map(attrs) do
    with {:ok, repo} <- text(attrs, :source_repository),
         {:ok, rev} <- exact_sha(attrs, :source_revision),
         {:ok, vocab} <- text(attrs, :semantic_vocabulary),
         {:ok, interface} <- digest(attrs, :interface_digest),
         {:ok, rule} <- text(attrs, :projection_rule),
         {:ok, runtime} <- text(attrs, :target_runtime),
         {:ok, artifact} <- digest(attrs, :artifact_digest),
         :ok <- none(attrs, :external_standing),
         :ok <- none(attrs, :runtime_authority) do
      payload = %{"schema" => "ash-a2a.semantic-interchange/v1",
        "source_repository" => repo, "source_revision" => rev,
        "semantic_vocabulary" => vocab, "interface_digest" => interface,
        "projection_rule" => rule, "target_runtime" => runtime,
        "artifact_digest" => artifact, "technical_standing" => "CANDIDATE",
        "external_standing" => "NONE", "runtime_authority" => "NONE"}
      {:ok, struct!(__MODULE__, source_repository: repo, source_revision: rev,
        semantic_vocabulary: vocab, interface_digest: interface, projection_rule: rule,
        target_runtime: runtime, artifact_digest: artifact, portable_identity: portable(payload))}
    end
  end
  def new(_), do: {:error, :semantic_interchange_invalid_input}

  def verify(%__MODULE__{} = c) do
    with {:ok, rebuilt} <- new(Map.from_struct(c)),
         true <- rebuilt.portable_identity == c.portable_identity || {:error, :semantic_interchange_identity_mismatch},
         true <- c.technical_standing == "CANDIDATE" || {:error, :semantic_interchange_self_declared_standing},
         true <- c.external_standing == "NONE" || {:error, :semantic_interchange_external_standing_conflated},
         true <- c.runtime_authority == "NONE" || {:error, :semantic_interchange_runtime_authority_conflated}, do: :ok
  end
  def verify(_), do: {:error, :semantic_interchange_invalid_input}

  def capability_candidate(%__MODULE__{} = c, id, version) do
    :ok = verify(c)
    AshA2A.CapabilityRelease.candidate(id, version, c.portable_identity,
      subject_revision: c.source_revision)
  end

  defp text(attrs, key) do
    case Map.get(attrs, key) do
      v when is_binary(v) and byte_size(v) > 0 -> {:ok, v}
      _ -> {:error, {:semantic_interchange_field_required, key}}
    end
  end
  defp exact_sha(attrs, key) do
    with {:ok, v} <- text(attrs, key),
         true <- Regex.match?(@sha40, v) || {:error, {:semantic_interchange_exact_subject_required, key}}, do: {:ok, v}
  end
  defp digest(attrs, key) do
    with {:ok, v} <- text(attrs, key),
         true <- Regex.match?(@digest, v) || {:error, {:semantic_interchange_digest_required, key}}, do: {:ok, v}
  end
  defp none(attrs, key), do: if(Map.get(attrs, key, "NONE") == "NONE", do: :ok, else: {:error, {:semantic_interchange_authority_ceiling, key}})
  defp portable(payload), do: "sha256:" <> (:crypto.hash(:sha256, Jcs.encode(payload)) |> Base.encode16(case: :lower))
end
