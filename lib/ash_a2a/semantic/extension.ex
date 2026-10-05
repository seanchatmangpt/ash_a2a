# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

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

  ## Where the advertisement rides -- the measured v1.0 reality

  The A2A v1.0 specification declares extensions under
  `AgentCard.capabilities.extensions`, and the ported encoder carries that
  key: `AshA2A.Protocol.JSON.encode_capabilities/1` ends with
  `put_unless_empty("extensions", encode_agent_extensions(...))`
  (lib/ash_a2a/protocol/json.ex:656), which passes each entry through
  `encode_agent_extension/1` (json.ex:663) -- a clause accepting exactly
  `%AshA2A.Protocol.AgentExtension{}` structs -- and the decoder rebuilds
  the same struct on the way back (json.ex:984). The old 0.2.0 whitelist
  that dropped any `extensions` key on the wire is gone; the workaround
  detour through `AgentCard.supportedInterfaces` (binding-name
  advertisement) is retired as the *only* ride.

  `capability_declaration/0` therefore returns the encoder's sole accepted
  shape, the `%AshA2A.Protocol.AgentExtension{}` struct, so a host
  advertises through the specification's own site directly:

      capabilities: %{extensions: [AshA2A.Semantic.Extension.capability_declaration()]}

  `advertise/1` and `supported_interface/1` remain as an additional
  `supportedInterfaces`-binding advertisement for callers that want the
  profile visible at the binding site too; `advertisement/1`,
  `advertised?/1` and `negotiate/2` classify that binding site.
  """

  @profile_id "SA2A-PROFILE-v26.9.20"
  @profile_uri "urn:sa2a:profile:v26.9.20"
  @profile_version "v26.9.20"
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

  @doc "The `AshA2A.Protocol.Message.extensions` key this profile occupies."
  @spec extension_key() :: String.t()
  def extension_key, do: @extension_key

  @doc """
  The A2A-specification-shaped extension declaration.

  This rides `AgentCard.capabilities.extensions` on the wire: the ported
  encoder's `encode_capabilities/1` carries that key
  (lib/ash_a2a/protocol/json.ex:656) and accepts exactly
  `%AshA2A.Protocol.AgentExtension{}` structs (json.ex:663), so this
  returns the struct itself. `required: false` is deliberate: a Semantic
  A2A agent must still answer ordinary A2A traffic (S75), it simply grants
  that traffic no semantic standing.
  """
  @spec capability_declaration() :: AshA2A.Protocol.AgentExtension.t()
  def capability_declaration do
    %AshA2A.Protocol.AgentExtension{
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
  @spec supported_interface(String.t()) :: AshA2A.Protocol.AgentCard.supported_interface()
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
  Whether a real `AshA2A.Protocol.AgentCard` advertises this profile at a compatible
  version.

  Accepts a decoded card struct or the raw decoded JSON map, so a peer can
  check a card it fetched over HTTP without first deciding which
  representation it holds. Anything else (including `nil`) is `false`.

  An entry naming this profile's binding at a different (or absent)
  `protocolVersion` is NOT an advertisement: assuming compatibility from the
  binding name alone is silent profile assumption (RFC-SA2A-002 §55,
  `SA2A-NEG-002`). See `advertisement/1` for the three-way answer.
  """
  @spec advertised?(AshA2A.Protocol.AgentCard.t() | map() | nil) :: boolean()
  def advertised?(card), do: advertisement(card) == :compatible

  @doc """
  What a card advertises for this profile: `:compatible`, `:absent`, or
  `{:incompatible, versions}` when the binding is present only at other
  `protocolVersion`s.
  """
  @spec advertisement(term()) :: :compatible | :absent | {:incompatible, [term()]}
  def advertisement(%AshA2A.Protocol.AgentCard{supported_interfaces: interfaces}) when is_list(interfaces) do
    classify_advertisement(
      for %{} = i <- interfaces,
          Map.get(i, :protocol_binding) == @profile_id,
          do: Map.get(i, :protocol_version)
    )
  end

  def advertisement(%{"supportedInterfaces" => interfaces}) when is_list(interfaces) do
    classify_advertisement(
      for %{} = i <- interfaces,
          Map.get(i, "protocolBinding") == @profile_id,
          do: Map.get(i, "protocolVersion")
    )
  end

  def advertisement(_card), do: :absent

  defp classify_advertisement([]), do: :absent

  defp classify_advertisement(versions) do
    if @profile_version in versions, do: :compatible, else: {:incompatible, versions}
  end

  @doc false
  def __sa2a_refusal_codes__ do
    %{
      unsupported_profile: :unsupported_profile,
      profile_version_incompatible: :unsupported_profile,
      profile_not_activated: :unsupported_profile,
      profile_payload_invalid: :refused_structure
    }
  end

  @doc """
  Explicit two-sided negotiation (S9).

  Both peers must advertise the profile. A one-sided advertisement is a
  refusal, not a downgrade -- the caller decides what to do next, and S76
  says a consequence-bearing task must not proceed.

  Returns `{:ok, profile_id}` or `{:error, refusal}` with code
  `:unsupported_profile` (an advertisement is absent) or
  `:profile_version_incompatible` (present only at another version).
  """
  @spec negotiate(AshA2A.Protocol.AgentCard.t() | map(), AshA2A.Protocol.AgentCard.t() | map()) ::
          {:ok, String.t()} | {:error, refusal()}
  def negotiate(local_card, remote_card) do
    local = advertisement(local_card)
    remote = advertisement(remote_card)
    result = decide_negotiation(local, remote)

    {outcome, code} =
      case result do
        {:ok, _} -> {:ok, nil}
        {:error, %{code: code}} -> {:refused, code}
      end

    # Boundary telemetry (RFC-SA2A-002 §12, §18): the negotiation decision.
    :telemetry.execute(
      [:ash_a2a, :semantic, :extension, :negotiate],
      %{system_time: System.system_time()},
      %{
        outcome: outcome,
        code: code,
        local_advertised: local == :compatible,
        remote_advertised: remote == :compatible,
        profile_id: @profile_id
      }
    )

    result
  end

  defp decide_negotiation(local, remote) do
    case {local, remote} do
      {:compatible, :compatible} ->
        {:ok, @profile_id}

      {:absent, :absent} ->
        {:error, refusal(:unsupported_profile, "neither peer advertises #{@profile_id}")}

      {:absent, _} ->
        {:error, refusal(:unsupported_profile, "local peer does not advertise #{@profile_id}")}

      {_, :absent} ->
        {:error, refusal(:unsupported_profile, "remote peer does not advertise #{@profile_id}")}

      {{:incompatible, versions}, _} ->
        {:error, incompatible("local", versions)}

      {_, {:incompatible, versions}} ->
        {:error, incompatible("remote", versions)}
    end
  end

  defp incompatible(side, versions) do
    refusal(
      :profile_version_incompatible,
      "#{side} peer advertises #{@profile_id} only at #{inspect(versions)}, not #{@profile_version}"
    )
  end

  @doc """
  Marks a real `AshA2A.Protocol.Message` as carrying Semantic A2A payload.

  The payload map is placed under this profile's single extension key.
  Everything already in `message.extensions` is preserved, so a message may
  carry other A2A extensions alongside this one.
  """
  @spec activate(AshA2A.Protocol.Message.t(), map()) :: AshA2A.Protocol.Message.t()
  def activate(%AshA2A.Protocol.Message{} = message, payload) when is_map(payload) do
    %{message | extensions: Map.put(message.extensions, @extension_key, payload)}
  end

  @doc """
  Whether a received message explicitly activated this profile.

  False for every ordinary A2A message. This is the mechanical form of "MUST
  NOT silently treat ordinary A2A traffic as Semantic A2A traffic": there is
  no heuristic here, no content sniffing, no "it looks like Turtle so it
  probably is semantic".
  """
  @spec activated?(AshA2A.Protocol.Message.t() | map()) :: boolean()
  def activated?(%AshA2A.Protocol.Message{extensions: extensions}), do: is_map_key(extensions, @extension_key)
  def activated?(%{} = extensions), do: is_map_key(extensions, @extension_key)
  def activated?(_), do: false

  @doc "Extracts this profile's raw payload from a message, if activated."
  @spec payload(AshA2A.Protocol.Message.t()) :: {:ok, map()} | {:error, refusal()}
  def payload(%AshA2A.Protocol.Message{extensions: extensions}) do
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
