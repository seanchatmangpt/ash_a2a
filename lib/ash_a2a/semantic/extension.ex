defmodule AshA2A.Semantic.Extension do
  @moduledoc """
  RFC-SA2A-001 S9 -- Semantic A2A profile negotiation over the real A2A
  extension mechanism.

  Two rules govern this module, and both are enforced mechanically rather
  than documented and hoped for:

    1. An implementation MUST NOT silently treat ordinary A2A traffic as
       Semantic A2A traffic. `activated?/1` is false for every message that
       does not carry this exact profile key, and `AshA2A.Semantic.Envelope`
       refuses to parse a message that is not activated.

    2. Both peers MUST explicitly negotiate before semantic standing may
       cross the boundary. `negotiate/2` requires the profile on *both*
       cards and returns a typed refusal otherwise.

  ## Where the advertisement actually rides -- a measured constraint

  The A2A specification declares extensions under
  `AgentCard.capabilities.extensions`. The vendored `:a2a` 0.2.0 encoder
  does not carry that key: `A2A.JSON.encode_agent_card/2` passes
  `capabilities` through `encode_capabilities/1`, which whitelists exactly
  `streaming`, `pushNotifications`, `stateTransitionHistory` and
  `extendedAgentCard`, and `decode_card_capabilities/1` whitelists the same
  four on the way back. Any `extensions` key placed there is dropped on the
  wire. `test/ash_a2a_semantic_extension_test.exs` asserts this drop
  directly against the real encoder rather than taking it on trust.

  So the wire-surviving advertisement is a real
  `AgentCard.supportedInterfaces` entry whose `protocolBinding` is the
  profile id. `encode_interfaces/1` carries `url`, `protocolBinding` and
  `protocolVersion` verbatim, and `decode_card_interfaces/1` reads all
  three back, so the advertisement makes a real HTTP round trip through the
  unmodified `:a2a` library.

  `capability_declaration/0` still returns the spec-shaped
  `%{uri:, description:, required:, params:}` map, so a host whose encoder
  *does* carry `capabilities.extensions` can advertise through the
  specification's own site without this module changing.
  """

  @profile_id "SA2A-PROFILE-v26.9.16"
  @profile_uri "urn:sa2a:profile:v26.9.16"
  @profile_version "v26.9.16"
  @extension_key "sa2a"

  @typedoc "Typed negotiation refusal. `code` is stable; `detail` is prose."
  @type refusal :: %{required(:code) => atom(), required(:detail) => String.t()}

  @doc "The profile identifier both peers must agree on."
  @spec profile_id() :: String.t()
  def profile_id, do: @profile_id

  @doc "The profile IRI, for RDF-side identification of the same profile."
  @spec profile_uri() :: String.t()
  def profile_uri, do: @profile_uri

  @doc "The profile version component."
  @spec profile_version() :: String.t()
  def profile_version, do: @profile_version

  @doc "The `A2A.Message.extensions` key this profile occupies."
  @spec extension_key() :: String.t()
  def extension_key, do: @extension_key

  @doc """
  The A2A-specification-shaped extension declaration.

  This is what belongs under `AgentCard.capabilities.extensions` on a host
  whose encoder carries that key. `required: false` is deliberate: a
  Semantic A2A agent must still answer ordinary A2A traffic (S75), it simply
  grants that traffic no semantic standing.
  """
  @spec capability_declaration() :: %{
          uri: String.t(),
          description: String.t(),
          required: boolean(),
          params: map()
        }
  def capability_declaration do
    %{
      uri: @profile_uri,
      description:
        "Semantic A2A: RDF-carrying envelopes admitted by the receiving peer's own " <>
          "GraphLaw engine before acquiring any standing.",
      required: false,
      params: %{
        "profileId" => @profile_id,
        "profileVersion" => @profile_version,
        "messageExtensionKey" => @extension_key
      }
    }
  end

  @doc """
  The `supportedInterfaces` entry that carries the advertisement on the wire.

  `url` is the peer's own A2A endpoint; the binding names the profile.
  """
  @spec supported_interface(String.t()) :: A2A.AgentCard.supported_interface()
  def supported_interface(url) when is_binary(url) do
    %{url: url, protocol_binding: @profile_id, protocol_version: @profile_version}
  end

  @doc """
  Adds the Semantic A2A advertisement to agent-card build options.

  Preserves whatever interfaces the caller already declared (the default
  JSON-RPC binding included) and appends this profile's entry. Idempotent:
  advertising twice produces one entry.
  """
  @spec advertise(keyword()) :: keyword()
  def advertise(opts) when is_list(opts) do
    url = Keyword.get(opts, :url, "http://localhost:4000")

    existing =
      Keyword.get(opts, :supported_interfaces) ||
        [%{url: url, protocol_binding: "JSONRPC", protocol_version: "0.3.0"}]

    interfaces =
      if Enum.any?(existing, &(Map.get(&1, :protocol_binding) == @profile_id)) do
        existing
      else
        existing ++ [supported_interface(url)]
      end

    Keyword.put(opts, :supported_interfaces, interfaces)
  end

  @doc """
  Whether a real `A2A.AgentCard` advertises this profile.

  Accepts a decoded card struct or the raw decoded JSON map, so a peer can
  check a card it fetched over HTTP without first deciding which
  representation it holds.
  """
  @spec advertised?(A2A.AgentCard.t() | map()) :: boolean()
  def advertised?(%A2A.AgentCard{supported_interfaces: interfaces}),
    do: Enum.any?(interfaces, &(Map.get(&1, :protocol_binding) == @profile_id))

  def advertised?(%{"supportedInterfaces" => interfaces}) when is_list(interfaces),
    do: Enum.any?(interfaces, &(Map.get(&1, "protocolBinding") == @profile_id))

  def advertised?(%{}), do: false

  @doc """
  Explicit two-sided negotiation (S9).

  Both peers must advertise the profile. A one-sided advertisement is a
  refusal, not a downgrade -- the caller decides what to do next, and S76
  says a consequence-bearing task must not proceed.

  Returns `{:ok, profile_id}` or `{:error, refusal}` with code
  `:unsupported_profile`.
  """
  @spec negotiate(A2A.AgentCard.t() | map(), A2A.AgentCard.t() | map()) ::
          {:ok, String.t()} | {:error, refusal()}
  def negotiate(local_card, remote_card) do
    case {advertised?(local_card), advertised?(remote_card)} do
      {true, true} ->
        {:ok, @profile_id}

      {false, true} ->
        {:error, refusal(:unsupported_profile, "local peer does not advertise #{@profile_id}")}

      {true, false} ->
        {:error, refusal(:unsupported_profile, "remote peer does not advertise #{@profile_id}")}

      {false, false} ->
        {:error, refusal(:unsupported_profile, "neither peer advertises #{@profile_id}")}
    end
  end

  @doc """
  Marks a real `A2A.Message` as carrying Semantic A2A payload.

  The payload map is placed under this profile's single extension key.
  Everything already in `message.extensions` is preserved, so a message may
  carry other A2A extensions alongside this one.
  """
  @spec activate(A2A.Message.t(), map()) :: A2A.Message.t()
  def activate(%A2A.Message{} = message, payload) when is_map(payload) do
    %{message | extensions: Map.put(message.extensions, @extension_key, payload)}
  end

  @doc """
  Whether a received message explicitly activated this profile.

  False for every ordinary A2A message. This is the mechanical form of "MUST
  NOT silently treat ordinary A2A traffic as Semantic A2A traffic": there is
  no heuristic here, no content sniffing, no "it looks like Turtle so it
  probably is semantic".
  """
  @spec activated?(A2A.Message.t() | map()) :: boolean()
  def activated?(%A2A.Message{extensions: extensions}), do: is_map_key(extensions, @extension_key)
  def activated?(%{} = extensions), do: is_map_key(extensions, @extension_key)
  def activated?(_), do: false

  @doc "Extracts this profile's raw payload from a message, if activated."
  @spec payload(A2A.Message.t()) :: {:ok, map()} | {:error, refusal()}
  def payload(%A2A.Message{extensions: extensions}) do
    case Map.get(extensions, @extension_key) do
      %{} = payload ->
        {:ok, payload}

      nil ->
        {:error,
         refusal(:profile_not_activated, "message carries no `#{@extension_key}` extension")}

      other ->
        {:error, refusal(:profile_payload_invalid, "expected a map, got #{inspect(other)}")}
    end
  end

  defp refusal(code, detail), do: %{code: code, detail: detail}
end
