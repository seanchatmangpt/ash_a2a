defmodule AshA2A.Semantic.Envelope do
  @moduledoc """
  RFC-SA2A-001 S8 -- the Semantic A2A envelope that crosses a peer boundary.

  ## Received is not admitted

  The single structural rule of this module: `parse/1` *always* produces an
  envelope whose `standing` is `:candidate`, no matter what the sender put
  on the wire. A sender that writes `"standing": "admitted"` into the
  payload gets an envelope whose standing is `:candidate`, and the claim it
  made is preserved separately as `claimed_standing` so the receiver can see
  that a peer asserted something it had no power to assert. There is no code
  path through this module that yields an admitted envelope. Standing is
  manufactured only by the receiving peer's own admission
  (`AshA2A.Semantic.Peer`), from its own engine, against its own shapes.

  This is the difference between Semantic A2A and serializing RDF between
  processes. Serializing RDF would let a sender's assertion arrive as a
  fact. Here it arrives as a claim about which the receiver has not yet
  decided anything.

  ## Wire form

  The envelope rides in `A2A.Message.extensions` under
  `AshA2A.Semantic.Extension.extension_key/0`, which the real vendored `:a2a`
  encoder and decoder both carry verbatim (`A2A.JSON.encode/1` for
  `%A2A.Message{}` does `put_unless_empty("extensions", msg.extensions)`;
  `A2A.JSON.decode(map, :message)` reads it straight back). So the envelope
  survives a real JSON-RPC `message/send` over real HTTP without this
  project patching the transport.

  The `graph_digest` a sender supplies is a *claim about* the graph, never a
  substitute for hashing it. `AshA2A.Semantic.Peer` recomputes the digest
  with its own engine and compares; a mismatch is a typed refusal.
  """

  alias AshA2A.Semantic.Extension

  @enforce_keys [:envelope_id, :profile, :origin_peer, :graph, :standing]
  defstruct [
    :envelope_id,
    :profile,
    :origin_peer,
    :graph,
    :capability_iri,
    :claimed_graph_digest,
    :claimed_standing,
    :claimed_authority,
    consequence_class: :unknown,
    standing: :candidate
  ]

  @type t :: %__MODULE__{
          envelope_id: String.t(),
          profile: String.t(),
          origin_peer: String.t(),
          graph: String.t(),
          capability_iri: String.t() | nil,
          claimed_graph_digest: String.t() | nil,
          claimed_standing: String.t() | nil,
          claimed_authority: String.t() | nil,
          consequence_class: AshA2A.Skill.consequence(),
          standing: :candidate
        }

  @type refusal :: %{required(:code) => atom(), required(:detail) => String.t()}

  @doc """
  Builds an outbound envelope.

  Note what this does *not* accept: there is no `standing:` option. A sender
  cannot construct an envelope that asserts its own admission, because the
  struct's `standing` is `:candidate` and nothing here writes any other
  value. A hostile peer can of course hand-write JSON claiming anything --
  that is what `claimed_standing` exists to record, and what `parse/1`
  neutralizes.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, refusal()}
  def new(opts) when is_list(opts) do
    graph = Keyword.get(opts, :graph)
    origin_peer = Keyword.get(opts, :origin_peer)

    cond do
      not is_binary(graph) or graph == "" ->
        {:error, refusal(:semantic_graph_missing, "`:graph` must be a non-empty Turtle string")}

      not is_binary(origin_peer) or origin_peer == "" ->
        {:error, refusal(:semantic_origin_missing, "`:origin_peer` must be a non-empty string")}

      true ->
        {:ok,
         %__MODULE__{
           envelope_id: Keyword.get(opts, :envelope_id) || generate_id(),
           profile: Extension.profile_id(),
           origin_peer: origin_peer,
           graph: graph,
           capability_iri: Keyword.get(opts, :capability_iri),
           claimed_graph_digest: Keyword.get(opts, :graph_digest),
           claimed_standing: nil,
           claimed_authority: nil,
           consequence_class: Keyword.get(opts, :consequence_class, :unknown),
           standing: :candidate
         }}
    end
  end

  @doc "Builds an outbound envelope or raises. For test setup and scripts."
  @spec new!(keyword()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, envelope} -> envelope
      {:error, refusal} -> raise ArgumentError, "invalid semantic envelope: #{inspect(refusal)}"
    end
  end

  @doc "The JSON-shaped payload placed under the profile's extension key."
  @spec to_payload(t()) :: map()
  def to_payload(%__MODULE__{} = envelope) do
    %{
      "envelopeId" => envelope.envelope_id,
      "profile" => envelope.profile,
      "originPeer" => envelope.origin_peer,
      "graph" => envelope.graph,
      "capabilityIri" => envelope.capability_iri,
      "graphDigest" => envelope.claimed_graph_digest,
      "consequenceClass" => to_string(envelope.consequence_class)
    }
  end

  @doc "Attaches an envelope to a real `A2A.Message` via the real extension key."
  @spec attach(A2A.Message.t(), t()) :: A2A.Message.t()
  def attach(%A2A.Message{} = message, %__MODULE__{} = envelope),
    do: Extension.activate(message, to_payload(envelope))

  @doc """
  Parses an inbound message into a **candidate** envelope.

  Refuses when the profile was not explicitly activated (S9: ordinary A2A
  traffic is never silently read as Semantic A2A traffic) and when the
  payload does not carry the profile this build speaks.

  Whatever standing or authority the sender claimed is recorded in
  `claimed_standing` / `claimed_authority` and is never copied into
  `standing`, which is `:candidate` on every successful parse.
  """
  @spec parse(A2A.Message.t()) :: {:ok, t()} | {:error, refusal()}
  def parse(%A2A.Message{} = message) do
    with {:ok, payload} <- Extension.payload(message) do
      parse_payload(payload)
    end
  end

  @doc "Parses a raw extension payload map into a candidate envelope."
  @spec parse_payload(map()) :: {:ok, t()} | {:error, refusal()}
  def parse_payload(%{} = payload) do
    profile = Map.get(payload, "profile")
    graph = Map.get(payload, "graph")
    origin_peer = Map.get(payload, "originPeer")

    cond do
      profile != Extension.profile_id() ->
        {:error,
         refusal(
           :unsupported_profile,
           "payload declares profile #{inspect(profile)}, this peer speaks " <>
             Extension.profile_id()
         )}

      not is_binary(graph) or graph == "" ->
        {:error, refusal(:semantic_graph_missing, "payload carries no `graph`")}

      not is_binary(origin_peer) or origin_peer == "" ->
        {:error, refusal(:semantic_origin_missing, "payload carries no `originPeer`")}

      true ->
        {:ok,
         %__MODULE__{
           envelope_id: Map.get(payload, "envelopeId") || generate_id(),
           profile: profile,
           origin_peer: origin_peer,
           graph: graph,
           capability_iri: Map.get(payload, "capabilityIri"),
           claimed_graph_digest: Map.get(payload, "graphDigest"),
           # Recorded, never honored.
           claimed_standing: Map.get(payload, "standing"),
           claimed_authority: Map.get(payload, "authority"),
           consequence_class: consequence_class(Map.get(payload, "consequenceClass")),
           standing: :candidate
         }}
    end
  end

  def parse_payload(other),
    do: {:error, refusal(:semantic_payload_invalid, "expected a map, got #{inspect(other)}")}

  @doc """
  Whether the sender asserted standing or authority it has no power to
  assert.

  Not itself a refusal: a receiver may legitimately choose to admit a graph
  whose sender over-claimed, because the sender's claim had no effect on the
  receiver's own admission. It is recorded so a receipt can show the
  over-claim was seen and ignored.
  """
  @spec over_claimed?(t()) :: boolean()
  def over_claimed?(%__MODULE__{claimed_standing: standing, claimed_authority: authority}) do
    (is_binary(standing) and standing != "candidate") or
      (is_binary(authority) and authority != "none")
  end

  defp consequence_class("observe"), do: :observe
  defp consequence_class("change"), do: :change
  defp consequence_class("external_do"), do: :external_do
  defp consequence_class(_), do: :unknown

  defp generate_id,
    do: "sa2a-env-" <> (16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower))

  defp refusal(code, detail), do: %{code: code, detail: detail}
end
