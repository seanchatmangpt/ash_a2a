defmodule AshA2A.Protocol.AgentCard do
  @moduledoc """
  Decoded agent card from the A2A discovery endpoint.

  Contains the agent's identity, capabilities, and skills as returned by
  `GET /.well-known/agent-card.json`. This is the wire-format struct used
  by clients; server-side agents define their card via the `agent_card/0` callback.

  ## v1.0 shape (spec §4.4/8.2, Appendix A.2.2)

  - `capabilities.extended_agent_card` — the `extendedAgentCard` member lives
    under `capabilities` on the wire, not top-level.
  - `supported_interfaces` entries carry transport identification via
    `protocol_binding` (`"JSONRPC" | "GRPC" | "HTTP+JSON"`) plus
    `protocol_version`.
  - `protocol_version` defaults to `AshA2A.Protocol.Version.protocol_version/0`
    (`"1.0"`).
  - Per-skill `input_modes` / `output_modes` (spec `AgentSkill` fields 6/7):
    OPTIONAL, overriding `default_input_modes` / `default_output_modes` for
    that skill. Absent (`nil`, key omitted by the builder/codec) means the
    skill inherits the card-level defaults.
  - Per-skill `security_requirements` (spec `AgentSkill` field 8, wire member
    `securityRequirements`, priv/a2a_v1_spec_corpus/a2a.proto:452): OPTIONAL
    list of flat `%{scheme-name => [scopes]}` maps — the same shape as the
    card-level `:security` entries. Absent (`nil`, key omitted by the
    builder/codec) means the skill inherits the card-level `security`.
    Declaration follows the existing builder-level opts pattern (as with
    per-skill modes; no DSL schema keys): the struct/codec surface is live
    (`AshA2A.Protocol.JSON` emits/reads `securityRequirements` on a skill only
    when present), and the card builder is the composition point.
  - `preferred_transport` — struct-only convenience field. The v1.0 proto
    defines NO top-level `preferredTransport` member (a2a.proto:362, fields
    1-14): transport preference is positional via `supported_interfaces`
    (first entry preferred, a2a.proto:370). `AshA2A.Protocol.JSON` therefore
    never reads or emits it — the exclusion is spec-correct, pinned by the
    proto-fidelity and wire-properties courts.

  ## Example

      {:ok, card} = AshA2A.Protocol.Client.discover("https://agent.example.com")
      card.name   #=> "my-agent"
      card.skills #=> [%{id: "greet", name: "Greet", ...}]
  """

  @type security_requirement :: %{String.t() => [String.t()]}

  @type skill :: %{
          required(:id) => String.t(),
          required(:name) => String.t(),
          required(:description) => String.t(),
          required(:tags) => [String.t()],
          optional(:input_modes) => [String.t()],
          optional(:output_modes) => [String.t()],
          optional(:security_requirements) => [security_requirement()]
        }

  @type capabilities :: %{
          optional(:streaming) => boolean(),
          optional(:push_notifications) => boolean(),
          optional(:state_transition_history) => boolean(),
          optional(:extended_agent_card) => boolean(),
          optional(:extensions) => [AshA2A.Protocol.AgentExtension.t()]
        }

  @type provider :: %{
          organization: String.t(),
          url: String.t()
        }

  @type supported_interface :: %{
          url: String.t(),
          protocol_binding: String.t(),
          protocol_version: String.t()
        }

  # `protocol_binding` carries the v1.0 transport identification values
  # `"JSONRPC" | "GRPC" | "HTTP+JSON"` (spec §4.4/8.2).

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          url: String.t(),
          version: String.t(),
          skills: [skill()],
          capabilities: capabilities(),
          default_input_modes: [String.t()],
          default_output_modes: [String.t()],
          provider: provider() | nil,
          documentation_url: String.t() | nil,
          icon_url: String.t() | nil,
          protocol_version: String.t() | nil,
          preferred_transport: String.t() | nil,
          supported_interfaces: [supported_interface()],
          security_schemes: %{String.t() => AshA2A.Protocol.SecurityScheme.t()},
          security: [%{String.t() => [String.t()]}],
          signatures: [map()]
        }

  # v1.0 default (spec §4.4/8.2): single source of truth is
  # AshA2A.Protocol.Version, not a local literal.
  @protocol_version AshA2A.Protocol.Version.protocol_version()

  @enforce_keys [:name, :description, :url, :version, :skills]
  defstruct [
    :name,
    :description,
    :url,
    :version,
    :provider,
    :documentation_url,
    :icon_url,
    :preferred_transport,
    protocol_version: @protocol_version,
    skills: [],
    capabilities: %{},
    default_input_modes: ["text/plain"],
    default_output_modes: ["text/plain"],
    supported_interfaces: [],
    security_schemes: %{},
    security: [],
    signatures: []
  ]
end
