defmodule AshA2A.Domain.Info do
  @moduledoc """
  Introspection for the `AshA2A.Domain` extension.

  Every getter reads flat `ash_a2a_domain_*` persisted keys via
  `Spark.Dsl.Extension.get_persisted/3` and returns the section defaults
  (`default_mount "/a2a"`, `streaming true`, `push_notifications false`) for
  any module that never declared them.
  """

  alias AshA2A.Domain.SecurityScheme
  alias Spark.Dsl.Extension

  @default_agent %{
    name: nil,
    description: nil,
    version: nil,
    url: nil,
    provider: nil,
    documentation_url: nil,
    icon_url: nil
  }

  @default_transport %{base_url: nil, mount: "/a2a", streaming: true, push_notifications: false}

  @doc "The full persisted `agent` section map."
  @spec agent(module()) :: %{
          name: String.t() | nil,
          description: String.t() | nil,
          version: String.t() | nil,
          url: String.t() | nil,
          provider: String.t() | nil,
          documentation_url: String.t() | nil,
          icon_url: String.t() | nil
        }
  def agent(domain), do: Extension.get_persisted(domain, :ash_a2a_domain_agent, @default_agent)

  @doc "The declared agent name."
  @spec agent_name(module()) :: String.t() | nil
  def agent_name(domain), do: agent(domain).name

  @doc "The declared agent description, if any."
  @spec agent_description(module()) :: String.t() | nil
  def agent_description(domain), do: agent(domain).description

  @doc "The declared agent version, if any."
  @spec agent_version(module()) :: String.t() | nil
  def agent_version(domain), do: agent(domain).version

  @doc "The declared AgentCard `url`, if any."
  @spec agent_url(module()) :: String.t() | nil
  def agent_url(domain), do: agent(domain).url

  @doc "The declared provider/organization, if any."
  @spec agent_provider(module()) :: String.t() | nil
  def agent_provider(domain), do: agent(domain).provider

  @doc "The declared documentation URL, if any."
  @spec agent_documentation_url(module()) :: String.t() | nil
  def agent_documentation_url(domain), do: agent(domain).documentation_url

  @doc "The declared icon URL, if any."
  @spec agent_icon_url(module()) :: String.t() | nil
  def agent_icon_url(domain), do: agent(domain).icon_url

  @doc "The full persisted `transport` section map."
  @spec transport(module()) :: %{
          base_url: String.t() | nil,
          mount: String.t(),
          streaming: boolean(),
          push_notifications: boolean()
        }
  def transport(domain),
    do: Extension.get_persisted(domain, :ash_a2a_domain_transport, @default_transport)

  @doc "The declared transport base URL, if any."
  @spec base_url(module()) :: String.t() | nil
  def base_url(domain), do: transport(domain).base_url

  @doc "The mount path (default `\"/a2a\"`; the `transport.default_mount` declaration)."
  @spec mount(module()) :: String.t()
  def mount(domain), do: transport(domain).mount

  @doc """
  Every declared per-agent transport mount, as `AshA2A.Domain.Mount`
  structs (default `[]`).
  """
  @spec mounts(module()) :: [AshA2A.Domain.Mount.t()]
  def mounts(domain),
    do: Extension.get_persisted(domain, :ash_a2a_domain_mounts, [])

  @doc """
  The domain-level default mount path (`transport.default_mount`, default
  `"/a2a"`).
  """
  @spec default_mount(module()) :: String.t()
  def default_mount(domain),
    do: Extension.get_persisted(domain, :ash_a2a_domain_default_mount, "/a2a")

  @doc "Whether SSE streaming is enabled (default `true`)."
  @spec streaming?(module()) :: boolean()
  def streaming?(domain), do: transport(domain).streaming

  @doc "Whether push notification delivery is enabled (default `false`)."
  @spec push_notifications?(module()) :: boolean()
  def push_notifications?(domain), do: transport(domain).push_notifications

  @doc "The declared security schemes, as `AshA2A.Domain.SecurityScheme` structs."
  @spec security_schemes(module()) :: [SecurityScheme.t()]
  def security_schemes(domain),
    do: Extension.get_persisted(domain, :ash_a2a_domain_security_schemes, [])

  @doc "Looks up one declared security scheme by name."
  @spec security_scheme(module(), atom()) ::
          {:ok, SecurityScheme.t()} | {:error, :scheme_not_found}
  def security_scheme(domain, name) do
    domain
    |> security_schemes()
    |> Enum.find(&(&1.name == name))
    |> case do
      nil -> {:error, :scheme_not_found}
      scheme -> {:ok, scheme}
    end
  end

  @doc "The module-level security requirements list (default `[]`)."
  @spec security_requirements(module()) :: [String.t()]
  def security_requirements(domain),
    do: Extension.get_persisted(domain, :ash_a2a_domain_security_requirements, [])

  @doc """
  The declared transports projected as A2A AgentCard `supportedInterfaces`
  entries: one entry per declared per-agent mount, with
  `transport.base_url` joined with the mount's `path` as the entry `url` and
  the mount's binding mapped through `AshA2A.Domain.Mount.protocol_binding/1`
  (`:jsonrpc` -> `"JSONRPC"`, `:rest` -> `"HTTP+JSON"`, `:grpc` -> `"GRPC"`).

  Entries are in declaration order. `[]` when the domain declares no
  per-agent mounts (the derived card then keeps its legacy single-JSONRPC
  default) and for any module without the `AshA2A.Domain` extension, so the
  getter is safe to call unconditionally.
  """
  @spec supported_interfaces(module()) :: [
          %{url: String.t(), protocol_binding: String.t()}
        ]
  def supported_interfaces(domain) do
    domain
    |> mounts()
    |> Enum.filter(&AshA2A.Domain.Mount.agent_mount?/1)
    |> case do
      [] ->
        []

      mounts ->
        base = base_url(domain)

        Enum.map(mounts, fn %AshA2A.Domain.Mount{path: path, binding: binding} ->
          %{
            url: join_url(base, path),
            protocol_binding: AshA2A.Domain.Mount.protocol_binding(binding)
          }
        end)
    end
  end

  defp join_url(nil, path), do: path
  defp join_url(base, path), do: Path.join(base, path)

  @doc """
  The derived agent-card identity (%{name, url, version, endpoint, mount}),
  or `nil` before the extension's transformer has run.
  """
  @spec card_identity(module()) ::
          %{
            name: String.t() | nil,
            url: String.t() | nil,
            version: String.t() | nil,
            endpoint: String.t() | nil,
            mount: String.t()
          }
          | nil
  def card_identity(domain),
    do: Extension.get_persisted(domain, :ash_a2a_domain_card_identity, nil)
end
