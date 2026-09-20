defmodule AshA2A.Gall.WorkLease do
  @moduledoc """
  The `gall:WorkLease` message (PRD §41 canonical shape, transported by the
  PRD §43.5 message fabric). The exact JSON shape MUST validate:

      {"type": "gall:WorkLease", "checkpoint": "urn:gall:checkpoint:xaas:001",
       "epoch": "urn:xaas:epoch:...", "lease": "urn:xaas:lease:...",
       "graphDigest": "sha256:..."}

  Namespace: `https://semantic-a2a.dev/gall#` (see `AshA2A.Gall.Message`).

  A lease message *describes* a lease relationship (checkpoint, epoch,
  lease IRI, graph digest). It is a transport payload, not the authority
  itself: carrying this message over A2A does not let the receiver actuate
  the epoch it names. The optional `capabilities` field carries the
  closed-vocabulary `requires`/`forbids` sets (`AshA2A.Gall.Capability`);
  the child-subset rule `Capabilities(child) ⊆ Capabilities(parent)`
  (PRD §30) is enforced by `AshA2A.Gall.Message.validate/2` when a parent
  grant is presented.

  Refusals are `{:refused, reason_string}` tuples. An unknown capability
  name is `{:refused, "REFUSED_CAPABILITY"}`; a malformed shape is
  `{:refused, "REFUSED_STRUCTURE"}`.
  """

  alias AshA2A.Gall.{Capability, Fields}

  @type_string "gall:WorkLease"

  @enforce_keys [:type, :checkpoint, :epoch, :lease, :graph_digest]
  defstruct [
    :type,
    :checkpoint,
    :epoch,
    :lease,
    :graph_digest,
    capabilities: %{requires: [], forbids: []}
  ]

  @type capabilities :: %{requires: [Capability.t()], forbids: [Capability.t()]}

  @type t :: %__MODULE__{
          type: String.t(),
          checkpoint: String.t(),
          epoch: String.t(),
          lease: String.t(),
          graph_digest: String.t(),
          capabilities: capabilities()
        }

  @doc "The message type literal this struct always carries."
  @spec type() :: String.t()
  def type, do: @type_string

  @doc """
  Builds and validates a work-lease message from an atom- or string-keyed
  map (or keyword list). `type` defaults to `"gall:WorkLease"` when absent
  and is refused when present with any other value. `capabilities` is
  optional and defaults to empty requires/forbids sets.
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
    epoch = Fields.fetch(attrs, :epoch, "epoch")
    lease = Fields.fetch(attrs, :lease, "lease")
    graph_digest = Fields.fetch(attrs, :graph_digest, "graphDigest")
    raw_capabilities = Fields.fetch(attrs, :capabilities, "capabilities")

    cond do
      not Fields.iri?(checkpoint) ->
        {:refused, "REFUSED_STRUCTURE"}

      not Fields.iri?(epoch) ->
        {:refused, "REFUSED_STRUCTURE"}

      not Fields.iri?(lease) ->
        {:refused, "REFUSED_STRUCTURE"}

      not Fields.sha256_digest?(graph_digest) ->
        {:refused, "REFUSED_STRUCTURE"}

      true ->
        with {:ok, capabilities} <- decode_capabilities(raw_capabilities) do
          {:ok,
           %__MODULE__{
             type: @type_string,
             checkpoint: checkpoint,
             epoch: epoch,
             lease: lease,
             graph_digest: graph_digest,
             capabilities: capabilities
           }}
        end
    end
  end

  defp decode_capabilities(nil), do: {:ok, %{requires: [], forbids: []}}

  defp decode_capabilities(raw) when is_map(raw) do
    requires = Fields.fetch(raw, :requires, "requires") || []
    forbids = Fields.fetch(raw, :forbids, "forbids") || []

    with {:ok, requires} <- decode_set(requires),
         {:ok, forbids} <- decode_set(forbids) do
      {:ok, %{requires: Enum.sort(requires), forbids: Enum.sort(forbids)}}
    end
  end

  defp decode_capabilities(_other), do: {:refused, "REFUSED_CAPABILITY"}

  defp decode_set(list) when is_list(list) do
    case Capability.decode_all(list) do
      {:ok, atoms} -> {:ok, Enum.uniq(atoms)}
      :error -> {:refused, "REFUSED_CAPABILITY"}
    end
  end

  defp decode_set(_other), do: {:refused, "REFUSED_CAPABILITY"}

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
      "epoch" => message.epoch,
      "lease" => message.lease,
      "graphDigest" => message.graph_digest,
      "capabilities" => %{
        "requires" => encode_set(message.capabilities.requires),
        "forbids" => encode_set(message.capabilities.forbids)
      }
    }
  end

  defp encode_set(atoms) do
    atoms
    |> Enum.sort()
    |> Enum.map(fn atom ->
      {:ok, label} = Capability.encode(atom)
      label
    end)
  end

  @doc "Serializes to a JSON binary via `Jason`."
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = message), do: message |> to_map() |> Jason.encode!()
end
