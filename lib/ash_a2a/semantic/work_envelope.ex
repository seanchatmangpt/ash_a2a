defmodule AshA2A.Semantic.WorkEnvelope do
  @moduledoc """
  Semantic transport envelope for GALL checkpoint, work-lease, and receipt
  identities.

  This module does not grant execution authority. It binds transport payloads
  to the repository's existing RDFC-1.0 canonical graph identity so a receiver
  can detect graph drift without trusting prose or a model reconstruction.
  """

  alias AshA2A.Semantic.CanonicalGraph

  @schema "gall.semantic-work/1"
  @sha ~r/^[0-9a-f]{40}$/
  @graph_digest ~r/^sha256:[0-9a-f]{64}$/
  @repository_identity ~r/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/

  @doc """
  Binds an authority-free checkpoint descriptor to the canonical Turtle graph.

  The descriptor graph digest MUST equal the digest actually computed by
  CanonicalGraph; caller-supplied identity cannot override observed identity.
  """
  @spec checkpoint(String.t(), map()) :: {:ok, map()} | {:error, map() | term()}
  def checkpoint(turtle, descriptor) when is_binary(turtle) and is_map(descriptor) do
    with {:ok, digest} <- CanonicalGraph.canonical_digest(turtle),
         observed_digest = "sha256:" <> digest,
         :ok <- require_iri(descriptor, "work_order_iri"),
         :ok <- require_iri(descriptor, "checkpoint_iri"),
         :ok <- require_match(descriptor, "repository_identity", @repository_identity),
         :ok <- require_match(descriptor, "base_sha", @sha),
         :ok <- require_match(descriptor, "graph_digest", @graph_digest),
         :ok <- require_equal(descriptor, "graph_digest", observed_digest),
         :ok <- capability_separation(descriptor) do
      {:ok,
       %{
         "schema" => @schema,
         "type" => "gall:CheckpointDescriptor",
         "work_order_iri" => fetch(descriptor, "work_order_iri"),
         "checkpoint_iri" => fetch(descriptor, "checkpoint_iri"),
         "repository_identity" => fetch(descriptor, "repository_identity"),
         "base_sha" => fetch(descriptor, "base_sha"),
         "graph_digest" => observed_digest,
         "canonicalization" => CanonicalGraph.algorithm_id(),
         "goal" => fetch(descriptor, "goal"),
         "verifier_suite" => fetch(descriptor, "verifier_suite"),
         "required_capabilities" => capabilities(descriptor, "required_capabilities"),
         "forbidden_capabilities" => capabilities(descriptor, "forbidden_capabilities"),
         "standing" => fetch(descriptor, "standing") || "UNKNOWN"
       }}
    end
  end

  def checkpoint(_turtle, _descriptor),
    do: {:error, %{code: :refused_semantic_work_descriptor}}

  @doc """
  Creates a transport lease envelope from an already bound checkpoint.

  The lease carries identity, not authority derivation. The receiving runtime
  still has to claim the named epoch through its real authority boundary.
  """
  @spec work_lease(map(), map()) :: {:ok, map()} | {:error, map()}
  def work_lease(%{"type" => "gall:CheckpointDescriptor"} = checkpoint, lease)
      when is_map(lease) do
    with :ok <- require_string(lease, "epoch_id"),
         :ok <- require_string(lease, "worker_id"),
         :ok <- require_string(lease, "worktree") do
      {:ok,
       %{
         "schema" => "gall.work-lease/1",
         "type" => "gall:WorkLease",
         "work_order_iri" => checkpoint["work_order_iri"],
         "checkpoint_iri" => checkpoint["checkpoint_iri"],
         "graph_digest" => checkpoint["graph_digest"],
         "repository_identity" => checkpoint["repository_identity"],
         "base_sha" => checkpoint["base_sha"],
         "epoch_id" => fetch(lease, "epoch_id"),
         "worker_id" => fetch(lease, "worker_id"),
         "worktree" => fetch(lease, "worktree")
       }}
    end
  end

  def work_lease(_, _), do: {:error, %{code: :refused_unbound_checkpoint}}

  @doc """
  Creates a receipt transport envelope without promoting observed standing.

  Standing is copied from the independent receipt. It is never inferred from a
  worker claim or from successful serialization.
  """
  @spec receipt(map(), map()) :: {:ok, map()} | {:error, map()}
  def receipt(%{"type" => "gall:CheckpointDescriptor"} = checkpoint, receipt)
      when is_map(receipt) do
    with :ok <- require_string(receipt, "receipt_iri"),
         :ok <- require_string(receipt, "candidate_sha"),
         :ok <- require_match(receipt, "candidate_sha", @sha),
         :ok <- require_string(receipt, "standing") do
      {:ok,
       %{
         "schema" => @schema,
         "type" => "gall:Receipt",
         "work_order_iri" => checkpoint["work_order_iri"],
         "checkpoint_iri" => checkpoint["checkpoint_iri"],
         "graph_digest" => checkpoint["graph_digest"],
         "repository_identity" => checkpoint["repository_identity"],
         "base_sha" => checkpoint["base_sha"],
         "receipt_iri" => fetch(receipt, "receipt_iri"),
         "candidate_sha" => fetch(receipt, "candidate_sha"),
         "standing" => fetch(receipt, "standing"),
         "verifier" => fetch(receipt, "verifier"),
         "replay_identity" => fetch(receipt, "replay_identity")
       }}
    end
  end

  def receipt(_, _), do: {:error, %{code: :refused_unbound_checkpoint}}

  defp capability_separation(descriptor) do
    required = MapSet.new(capabilities(descriptor, "required_capabilities"))
    forbidden = MapSet.new(capabilities(descriptor, "forbidden_capabilities"))

    case MapSet.intersection(required, forbidden) |> MapSet.to_list() do
      [] -> :ok
      overlap -> {:error, %{code: :refused_capability_contradiction, capabilities: overlap}}
    end
  end

  defp capabilities(map, key) do
    case fetch(map, key) do
      list when is_list(list) -> Enum.map(list, &to_string/1)
      _ -> []
    end
  end

  defp require_iri(map, key) do
    case fetch(map, key) do
      value when is_binary(value) and value != "" ->
        if String.contains?(value, ":"),
          do: :ok,
          else: {:error, %{code: :refused_invalid_semantic_field, field: key}}

      _ ->
        {:error, %{code: :refused_missing_semantic_field, field: key}}
    end
  end

  defp require_string(map, key) do
    case fetch(map, key) do
      value when is_binary(value) and value != "" -> :ok
      _ -> {:error, %{code: :refused_missing_semantic_field, field: key}}
    end
  end

  defp require_match(map, key, regex) do
    case fetch(map, key) do
      value when is_binary(value) ->
        if Regex.match?(regex, value),
          do: :ok,
          else: {:error, %{code: :refused_invalid_semantic_field, field: key}}

      _ ->
        {:error, %{code: :refused_invalid_semantic_field, field: key}}
    end
  end

  defp require_equal(map, key, observed) do
    if fetch(map, key) == observed,
      do: :ok,
      else:
        {:error,
         %{
           code: :refused_graph_identity_mismatch,
           field: key,
           supplied: fetch(map, key),
           observed: observed
         }}
  end

  defp fetch(map, key) do
    Map.get(map, key) || atom_key(map, key)
  end

  defp atom_key(map, key) do
    atom =
      case key do
        "work_order_iri" -> :work_order_iri
        "checkpoint_iri" -> :checkpoint_iri
        "repository_identity" -> :repository_identity
        "repository" -> :repository_identity
        "base_sha" -> :base_sha
        "graph_digest" -> :graph_digest
        "goal" -> :goal
        "verifier_suite" -> :verifier_suite
        "required_capabilities" -> :required_capabilities
        "forbidden_capabilities" -> :forbidden_capabilities
        "standing" -> :standing
        "epoch_id" -> :epoch_id
        "worker_id" -> :worker_id
        "worktree" -> :worktree
        "receipt_iri" -> :receipt_iri
        "candidate_sha" -> :candidate_sha
        "verifier" -> :verifier
        "replay_identity" -> :replay_identity
        _ -> nil
      end

    if atom, do: Map.get(map, atom), else: nil
  end
end
