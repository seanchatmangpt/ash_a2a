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
          optional(:security_requirements) => [security_requirement()],
          optional(:examples) => [String.t()]
        }

  @type capabilities :: %{
          optional(:streaming) => boolean(),
          optional(:push_notifications) => boolean(),
          optional(:state_transition_history) => boolean(),
          optional(:extended_agent_card) => boolean(),
          optional(:user_artifacts) => boolean(),
          optional(:live) => boolean(),
          optional(:extensions) => [AshA2A.Protocol.AgentExtension.t()]
        }

  @type provider :: %{
          organization: String.t(),
          url: String.t()
        }

  @type supported_interface :: %{
          required(:url) => String.t(),
          required(:protocol_binding) => String.t(),
          required(:protocol_version) => String.t(),
          optional(:tenant) => String.t()
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

  @typedoc "One discrepancy between a card and what is mounted/enabled."
  @type discrepancy :: %{code: atom(), message: String.t()}

  @capability_keys [
    {:streaming, "streaming"},
    {:push_notifications, "pushNotifications"},
    {:live, "live"},
    {:user_artifacts, "userArtifacts"},
    {:extended_agent_card, "extendedAgentCard"}
  ]

  @known_bindings ["JSONRPC", "GRPC", "HTTP+JSON"]

  @doc """
  Audits a card against what is actually mounted and enabled, returning a list
  of `%{code: atom, message: String.t()}` discrepancies (`[]` means honest).

  `card` is an `%AshA2A.Protocol.AgentCard{}` or its wire map (string keys).

  `mounted_opts` (keyword or map) describes the mounted surface:

    * `:domain` - an `AshA2A.Domain` module; unset expectations are derived
      from `AshA2A.Domain.Info` (declared mounts, `streaming`,
      `push_notifications`, `extended_agent_card`, `user_artifacts`, security
      schemes) and `AshA2A.Info.released_capability_index/1` (skills).
    * `:bindings` - allowed `protocolBinding` strings (overrides the domain).
    * `:streaming`, `:push_notifications`, `:live`, `:user_artifacts`,
      `:extended_agent_card` - booleans (override the domain). A capability
      with no expectation is treated as NOT enabled, so advertising it fails.
    * `:skill_ids` - allowed skill ids (overrides the domain's index).
    * `:security_schemes` - allowed scheme names (overrides the domain).

  Codes: `:unmounted_binding`, `:unknown_binding`, `:capability_not_enabled`,
  `:skill_not_public`, `:security_scheme_not_configured`,
  `:security_requirement_undeclared`.

  Without `:domain`, no mount list is known, so only the legacy default
  `"JSONRPC"` binding is accepted unless `:bindings` says otherwise.
  """
  @spec audit(t() | map(), keyword() | map()) :: [discrepancy()]
  def audit(card, mounted_opts \\ []) do
    opts = Map.new(mounted_opts)
    view = card_view(card)
    domain = Map.get(opts, :domain)

    binding_issues(view.bindings, expected_bindings(opts, domain)) ++
      capability_issues(view.capabilities, opts, domain) ++
      skill_issues(view.skill_ids, expected_skill_ids(opts, domain)) ++
      security_issues(view, expected_scheme_names(opts, domain))
  end

  defp card_view(%__MODULE__{} = card) do
    %{
      bindings:
        Enum.map(
          card.supported_interfaces || [],
          &fetch(&1, :protocol_binding, "protocolBinding")
        ),
      capabilities: card.capabilities || %{},
      skill_ids: Enum.map(card.skills || [], &fetch(&1, :id, "id")),
      scheme_names: Enum.map(Map.keys(card.security_schemes || %{}), &to_string/1),
      requirement_names:
        (card.security || []) |> Enum.flat_map(&Map.keys/1) |> Enum.map(&to_string/1)
    }
  end

  defp card_view(%{} = wire) do
    %{
      bindings:
        Enum.map(
          fetch(wire, :supported_interfaces, "supportedInterfaces") || [],
          &fetch(&1, :protocol_binding, "protocolBinding")
        ),
      capabilities: fetch(wire, :capabilities, "capabilities") || %{},
      skill_ids: Enum.map(fetch(wire, :skills, "skills") || [], &fetch(&1, :id, "id")),
      scheme_names:
        (fetch(wire, :security_schemes, "securitySchemes") || %{})
        |> Map.keys()
        |> Enum.map(&to_string/1),
      requirement_names:
        (fetch(wire, :security, "securityRequirements") || [])
        |> Enum.flat_map(fn req ->
          case req do
            %{"schemes" => schemes} -> Map.keys(schemes)
            flat -> Map.keys(flat)
          end
        end)
        |> Enum.map(&to_string/1)
    }
  end

  defp fetch(map, atom_key, string_key) when is_map(map) do
    case Map.fetch(map, atom_key) do
      {:ok, value} -> value
      :error -> Map.get(map, string_key)
    end
  end

  defp expected_bindings(%{bindings: bindings}, _domain) when is_list(bindings), do: bindings
  defp expected_bindings(_opts, nil), do: ["JSONRPC"]

  defp expected_bindings(_opts, domain) do
    case AshA2A.Domain.Info.supported_interfaces(domain) do
      [] -> ["JSONRPC"]
      interfaces -> Enum.map(interfaces, & &1.protocol_binding)
    end
  end

  defp binding_issues(actual, allowed) do
    Enum.flat_map(Enum.uniq(actual), fn binding ->
      cond do
        binding not in @known_bindings ->
          [
            %{
              code: :unknown_binding,
              message:
                "supportedInterfaces advertises unknown protocolBinding #{inspect(binding)}"
            }
          ]

        binding not in allowed ->
          [
            %{
              code: :unmounted_binding,
              message:
                "supportedInterfaces advertises #{binding} but only #{inspect(allowed)} is mounted"
            }
          ]

        true ->
          []
      end
    end)
  end

  defp expected_flag(opts, key, domain) do
    case Map.fetch(opts, key) do
      {:ok, value} -> value == true
      :error -> domain_flag(domain, key)
    end
  end

  defp domain_flag(nil, _key), do: false
  defp domain_flag(_domain, :live), do: false

  defp domain_flag(domain, key) do
    Map.get(AshA2A.Domain.Info.transport(domain), key, false) == true
  end

  defp capability_issues(capabilities, opts, domain) do
    Enum.flat_map(@capability_keys, fn {atom_key, wire_key} ->
      advertised = fetch(capabilities, atom_key, wire_key) == true

      if advertised and not expected_flag(opts, atom_key, domain) do
        [
          %{
            code: :capability_not_enabled,
            message: "capabilities.#{wire_key} is advertised but its code path is not enabled"
          }
        ]
      else
        []
      end
    end)
  end

  defp expected_skill_ids(%{skill_ids: ids}, _domain) when is_list(ids), do: ids
  defp expected_skill_ids(_opts, nil), do: nil

  defp expected_skill_ids(_opts, domain) do
    case AshA2A.Info.capability_index(domain) do
      nil ->
        nil

      index ->
        Enum.map(index, fn
          %{id: id} when is_binary(id) ->
            id

          %{resource: resource, action: action} ->
            AshA2A.CapabilityIndex.Compiler.capability_id(resource, action)
        end)
    end
  end

  defp skill_issues(_actual, nil), do: []

  defp skill_issues(actual, allowed) do
    for id <- actual, id not in allowed do
      %{
        code: :skill_not_public,
        message: "skill #{inspect(id)} does not derive from a public action of the subject"
      }
    end
  end

  defp expected_scheme_names(%{security_schemes: names}, _domain) when is_list(names),
    do: Enum.map(names, &to_string/1)

  defp expected_scheme_names(_opts, nil), do: []

  defp expected_scheme_names(_opts, domain) do
    domain |> AshA2A.Domain.Info.security_schemes() |> Enum.map(&to_string(&1.name))
  end

  defp security_issues(view, configured) do
    unconfigured =
      for name <- view.scheme_names, name not in configured do
        %{
          code: :security_scheme_not_configured,
          message: "securitySchemes advertises #{inspect(name)} but no such auth is configured"
        }
      end

    undeclared =
      for name <- Enum.uniq(view.requirement_names), name not in view.scheme_names do
        %{
          code: :security_requirement_undeclared,
          message: "securityRequirements references #{inspect(name)} absent from securitySchemes"
        }
      end

    unconfigured ++ undeclared
  end
end
