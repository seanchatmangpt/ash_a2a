defmodule AshA2A.Domain do
  @moduledoc """
  Domain-side `AshA2A` extension: agent identity, security and transport
  configuration declared once per `Ash.Domain`.

  Attach with `use Ash.Domain, extensions: [AshA2A.Domain]`.

  ```elixir
  defmodule MyApp.Domain do
    use Ash.Domain, extensions: [AshA2A.Domain]

    agent do
      name "my-agent"
      description "Example agent"
      version "1.2.3"
      provider "Example Org"
    end

    transport do
      base_url "https://example.com"
      default_mount "/a2a"
      streaming true
      push_notifications false

      mount agent: MyApp.EchoAgent, path: "/echo", binding: :jsonrpc
      mount agent: MyApp.RestAgent, path: "/rest", binding: :rest
    end

    security do
      security_scheme :token, :bearer
      requirements ["token"]
    end
  end
  ```

  All values are persisted under flat `ash_a2a_domain_*` keys and read back
  through `AshA2A.Domain.Info`. Nothing here manufactures capability: the
  exposed surface is still derived from `Ash.Resource.Info.public_actions/1`
  by the resource-side `AshA2A` extension; this module only carries the
  agent-card identity, transport placement and security envelope.

  ## Domain-level transport is the default

  As with ash_json_api, where domain-level route definition (`base_route` as
  scope) is the documented default and per-resource routing is the exception,
  declaring your agents' transport placement once on the domain is the
  default recommendation:

      transport do
        base_url "https://agents.example.com"

        mount agent: MyApp.EchoAgent, path: "/echo", binding: :jsonrpc
        mount agent: MyApp.RestAgent, path: "/rest", binding: :rest
      end

  and serving the whole surface with one plug:

      forward "/", AshA2A.Domain.Router, domain: MyApp.Domain

  Each mount is served at its declared path over its declared binding
  (`:jsonrpc` -> `AshA2A.A2ATransport.Plug`, `:rest` ->
  `AshA2A.Transport.HTTPJSON`; a `:grpc` mount is served by
  `AshA2A.Transport.GRPC.Server.Endpoint` on its own port and answers a
  typed 501 when routed through the router). Mounted agents must be compiled
  before the domain that mounts them; a mount naming a module that does not
  exist is a compile-time `Spark.Error.DslError` refusal
  (`AshA2A.Domain.Verifiers.VerifyMounts`).

  Per-agent mounting -- `forward "/echo", AshA2A.A2ATransport.Plug,
  agent: MyApp.EchoAgent` -- remains fully supported as the exception, for
  the same cases ash_json_api reserves per-resource routes for: one-off
  placement, a third-party router that owns the paths, or a single agent
  with no domain-level surface worth naming.
  """

  alias AshA2A.Domain.Mount
  alias AshA2A.Domain.SecurityScheme

  @agent_schema [
    name: [
      type: :string,
      required: false,
      doc: """
      The agent's declared name. Required: `AshA2A.Domain.Verifiers.VerifyConfig`
      refuses to compile a domain whose `agent` block omits it.
      """
    ],
    description: [
      type: :string,
      required: false,
      doc: "Optional A2A AgentCard `description`."
    ],
    version: [
      type: :string,
      required: false,
      doc: "Optional A2A AgentCard `version` string."
    ],
    url: [
      type: :string,
      required: false,
      doc: """
      Optional AgentCard `url` used when the `transport` section declares no
      `base_url` (which itself only draws a verifier warning, not an error).
      """
    ],
    provider: [
      type: :string,
      required: false,
      doc: "Optional provider/organization name for the AgentCard."
    ],
    documentation_url: [
      type: :string,
      required: false,
      doc: "Optional documentation URL for the AgentCard."
    ],
    icon_url: [
      type: :string,
      required: false,
      doc: "Optional icon URL for the AgentCard."
    ]
  ]

  @agent %Spark.Dsl.Section{
    name: :agent,
    describe: "Agent-card identity for this domain.",
    schema: @agent_schema
  }

  @scheme_kinds [:bearer, :api_key, :none]

  @security_scheme %Spark.Dsl.Entity{
    name: :security_scheme,
    describe: "Declares one A2A security scheme.",
    examples: ["security_scheme :token, :bearer"],
    target: SecurityScheme,
    args: [:name, :kind],
    identifier: :name,
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "Scheme selector name."
      ],
      kind: [
        type: {:one_of, @scheme_kinds},
        required: true,
        doc:
          "Scheme kind, one of `:bearer`, `:api_key` or `:none`. Verified again " <>
            "at the verifier layer (atoms in the allowed set)."
      ]
    ]
  }

  @security %Spark.Dsl.Section{
    name: :security,
    describe: "Security schemes and the module-level requirements list.",
    entities: [@security_scheme],
    schema: [
      requirements: [
        type: {:list, :string},
        default: [],
        doc:
          "Module-level security requirements: names of `security_scheme` " <>
            "declarations that must be satisfied to talk to this agent."
      ]
    ]
  }

  @mount %Spark.Dsl.Entity{
    name: :mount,
    describe: "Mounts one compiled agent at a path over a transport binding.",
    examples: [
      "mount agent: MyApp.EchoAgent, path: \"/echo\", binding: :jsonrpc",
      "mount agent: MyApp.RestAgent, path: \"/rest\", binding: :rest"
    ],
    target: Mount,
    # Keyword-only (args: []): a Spark entity with positional args cannot
    # also accept the keyword spelling -- the keyword list is consumed by the
    # trailing positional arg (pinned by test/gi_probe2_test.exs).
    args: [],
    schema: [
      agent: [
        type: :atom,
        required: true,
        doc: """
        The `AshA2A.Agent` module to serve at `path`. Must be compiled before
        the domain that mounts it: a module that does not exist is a
        compile-time `Spark.Error.DslError` refusal.
        """
      ],
      path: [
        type: :string,
        required: true,
        doc: "Path the agent is served at (unique across all mounts)."
      ],
      binding: [
        type: {:one_of, Mount.bindings()},
        default: :jsonrpc,
        doc:
          "Transport binding of the mount: `:jsonrpc` (default), `:rest` or `:grpc`. " <>
            "`:grpc` mounts are served by `AshA2A.Transport.GRPC.Server.Endpoint` on its " <>
            "own port; `AshA2A.Domain.Router` answers them with a typed 501 refusal."
      ]
    ]
  }

  @transport %Spark.Dsl.Section{
    name: :transport,
    describe: "Transport placement for this domain's A2A surface.",
    entities: [@mount],
    schema: [
      base_url: [
        type: :string,
        required: false,
        doc: """
        Base URL this agent is served from. Optional: when neither this nor
        `agent.url` is set, the verifier emits a warning (not an error).
        """
      ],
      default_mount: [
        type: :string,
        default: "/a2a",
        doc: """
        Default mount path of the domain's A2A endpoint under `base_url`.
        (Named `default_mount`, not `mount`: a section option and entity with
        the same name make every use ambiguous at compile time. The `mount`
        entity is the per-agent mount declaration.)
        """
      ],
      streaming: [
        type: :boolean,
        default: true,
        doc: "Whether SSE streaming is enabled for this domain."
      ],
      push_notifications: [
        type: :boolean,
        default: false,
        doc: "Whether push notification delivery is enabled for this domain."
      ]
    ]
  }

  @sections [@agent, @security, @transport]

  use Spark.Dsl.Extension,
    sections: @sections,
    transformers: [
      AshA2A.Domain.Transformers.PersistMounts,
      AshA2A.Domain.Transformers.PersistConfig
    ],
    verifiers: [
      AshA2A.Domain.Verifiers.VerifyConfig,
      AshA2A.Domain.Verifiers.VerifyMounts
    ]

  @doc "The set of allowed security scheme kinds."
  @spec scheme_kinds() :: [atom()]
  def scheme_kinds, do: @scheme_kinds

  @doc """
  Derives the agent-card identity from the persisted `agent` and `transport`
  maps. `transport.base_url` wins over `agent.url`; the full endpoint is
  `base_url <> mount` when a `base_url` is declared.
  """
  @spec card_identity(map(), map()) ::
          %{name: String.t() | nil, url: String.t() | nil, version: String.t() | nil,
            endpoint: String.t() | nil, mount: String.t()}
  def card_identity(agent, transport) do
    url = transport[:base_url] || agent[:url]
    mount = transport[:mount] || "/a2a"

    %{
      name: agent[:name],
      url: url,
      version: agent[:version],
      endpoint: url && Path.join(url, mount),
      mount: mount
    }
  end
end
