defmodule AshA2A.Gall.Checkpoint do
  @moduledoc """
  The `gall:CodingCheckpoint` identity message (PRD §43.5): a typed
  *reference* to a repository checkpoint. It names a checkpoint; it never
  authorizes anything to be done at it.

  Fields:

    * `type` -- always `"gall:CodingCheckpoint"`.
    * `checkpoint` -- the checkpoint IRI (e.g. `urn:gall:checkpoint:xaas:001`).
    * `repository` -- the repository IRI.
    * `base_sha` -- the 40-hex base git object SHA.
    * `graph_digest` -- the typed `sha256:...` graph digest.

  Wire keys are camelCase (`baseSha`, `graphDigest`), struct keys
  snake_case, matching `AshA2A.Semantic.Envelope`'s convention. Refusals
  are `{:refused, reason_string}` tuples; see `AshA2A.Gall.Message` for
  the transport-is-not-authority law that governs every `gall:*` message.
  """

  alias AshA2A.Gall.Fields

  @type_string "gall:CodingCheckpoint"

  @enforce_keys [:type, :checkpoint, :repository, :base_sha, :graph_digest]
  defstruct [:type, :checkpoint, :repository, :base_sha, :graph_digest]

  @type t :: %__MODULE__{
          type: String.t(),
          checkpoint: String.t(),
          repository: String.t(),
          base_sha: String.t(),
          graph_digest: String.t()
        }

  @doc "The message type literal this struct always carries."
  @spec type() :: String.t()
  def type, do: @type_string

  @doc """
  Builds and validates a checkpoint message from an atom- or string-keyed
  map (or keyword list). `type` defaults to `"gall:CodingCheckpoint"` when
  absent and is refused when present with any other value.
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
    checkpoint = Fields.fetch(attrs, :checkpoint, "checkpoint")
    repository = Fields.fetch(attrs, :repository, "repository")
    base_sha = Fields.fetch(attrs, :base_sha, "baseSha")
    graph_digest = Fields.fetch(attrs, :graph_digest, "graphDigest")

    cond do
      not Fields.iri?(checkpoint) ->
        {:refused, "REFUSED_STRUCTURE"}

      not Fields.iri?(repository) ->
        {:refused, "REFUSED_STRUCTURE"}

      not Fields.hex40?(base_sha) ->
        {:refused, "REFUSED_STRUCTURE"}

      not Fields.sha256_digest?(graph_digest) ->
        {:refused, "REFUSED_STRUCTURE"}

      true ->
        {:ok,
         %__MODULE__{
           type: @type_string,
           checkpoint: checkpoint,
           repository: repository,
           base_sha: base_sha,
           graph_digest: graph_digest
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
      "checkpoint" => message.checkpoint,
      "repository" => message.repository,
      "baseSha" => message.base_sha,
      "graphDigest" => message.graph_digest
    }
  end

  @doc "Serializes to a JSON binary via `Jason`."
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = message), do: message |> to_map() |> Jason.encode!()
end
