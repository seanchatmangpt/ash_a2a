defmodule AshA2A.Chicago.Fixtures.EnvelopeNegotiationTransport do
  @moduledoc """
  Real collaborators for the RFC-SA2A-002 §54/§55/§56/§75 courts
  (`AshA2A.Chicago.Courts.SemanticEnvelope`,
  `AshA2A.Chicago.Courts.ExtensionNegotiation`,
  `AshA2A.Chicago.Courts.TransportIndependence`).

  Nothing here replaces a component under qualification. The receiving
  boundary is the real `AshA2A.Semantic.Peer` inside a real `A2A.Agent`
  GenServer; the engine is the real praxis-graphlaw wasm; the HTTP binding is
  the real, unmodified `A2A.Plug` (optionally behind the real
  `A2A.Plug.Auth`) on a real local Bandit listener; the consequence path is
  the real `AshA2A.Agent` -> `AshA2A.CommandBus` over a real ETS-backed Ash
  resource.
  """

  alias AshA2A.Semantic.{Envelope, Extension, GraphLaw}

  @doc "A unique, collision-free suffix for per-run process names and labels."
  @spec unique(String.t()) :: String.t()
  def unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  @doc "True when the real GraphLaw engine answers a real version call."
  @spec engine_available?() :: boolean()
  def engine_available?, do: match?({:ok, _}, GraphLaw.version())

  defmodule Graphs do
    @moduledoc "Real Turtle order graphs and the receiving peer's own SHACL shapes."

    @doc "A conforming order graph."
    @spec conforming() :: String.t()
    def conforming do
      """
      @prefix ex: <http://example.org/> .
      ex:order-1 a ex:Order ;
        ex:item "widget" ;
        ex:quantity 3 .
      """
    end

    @doc "An order graph missing the `ex:item` the receiving peer's shapes require."
    @spec nonconforming() :: String.t()
    def nonconforming do
      """
      @prefix ex: <http://example.org/> .
      ex:order-1 a ex:Order ;
        ex:quantity 3 .
      """
    end

    @doc "The receiving peer's own SHACL shapes. Never supplied by a sender."
    @spec shapes() :: String.t()
    def shapes do
      """
      @prefix sh: <http://www.w3.org/ns/shacl#> .
      @prefix ex: <http://example.org/> .

      ex:OrderShape a sh:NodeShape ;
        sh:targetClass ex:Order ;
        sh:property [ sh:path ex:item ; sh:minCount 1 ] ;
        sh:property [ sh:path ex:quantity ; sh:minCount 1 ] .
      """
    end
  end

  defmodule Envelopes do
    @moduledoc """
    Wire-shaped (RFC-SA2A-001 S11, camelCase) envelope payloads and activated
    `A2A.Message`s, as a remote sender would put them on the wire.
    """

    @doc """
    A fully admissible payload: identity, known profile, non-empty semantic
    basis, the sender's real engine digest of the graph it carries,
    provenance, lawful consequence/authority classes, no receipt claims.
    `digest` must be the real `GraphLaw.graph_hash/1` of `graph`.
    """
    @spec admissible(String.t(), String.t(), map()) :: map()
    def admissible(graph, digest, overrides \\ %{}) do
      Map.merge(
        %{
          "profile" => Envelope.default_profile(),
          "kind" => "sa2a:Request",
          "envelopeId" => "urn:uuid:" <> Ash.UUIDv7.generate(),
          "subjects" => ["http://example.org/order-1"],
          "semanticBasis" => ["urn:sa2a:basis:chicago:order-shapes:v26.9.16"],
          "graph" => %{"mediaType" => "text/turtle", "digest" => digest, "content" => graph},
          "provenance" => %{
            "agent" => "urn:sa2a:peer:chicago-remote-sender",
            "wasGeneratedBy" => "urn:sa2a:activity:chicago-court-stimulus"
          },
          "consequenceClass" => "none",
          "authorityRequirement" => "none",
          "bounds" => %{},
          "receipts" => []
        },
        overrides
      )
    end

    @doc "An `A2A.Message` that explicitly activates the SA2A extension."
    @spec activated(map(), map()) :: A2A.Message.t()
    def activated(payload, metadata \\ %{}) do
      message = A2A.Message.new_user([A2A.Part.Text.new("semantic request")])
      %{Extension.activate(message, payload) | metadata: metadata}
    end

    @doc "An ordinary (never activated) `A2A.Message`."
    @spec ordinary([A2A.Part.t()] | String.t(), map()) :: A2A.Message.t()
    def ordinary(parts, metadata \\ %{}) do
      %{A2A.Message.new_user(parts) | metadata: metadata}
    end
  end

  defmodule Ordering do
    @moduledoc """
    Real ETS-backed Ash resource with one consequence-bearing capability
    (`:place_order`, `:change`) and one observation (`:list_orders`).
    """

    use Ash.Resource,
      domain: AshA2A.Chicago.Fixtures.EnvelopeNegotiationTransport.OrderingDomain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshA2A]

    attributes do
      uuid_primary_key(:id)
      attribute(:item, :string, public?: true)
      attribute(:quantity, :integer, public?: true)
    end

    actions do
      defaults([:read, create: [:item, :quantity]])
    end

    a2a do
      skill(:place_order, :create)
      skill(:list_orders, :read)
    end
  end

  defmodule OrderingDomain do
    @moduledoc "Domain for `Ordering`."
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(AshA2A.Chicago.Fixtures.EnvelopeNegotiationTransport.Ordering)
    end
  end

  defmodule Catalog do
    @moduledoc "Real ETS-backed Ash resource whose only capability is an observation."

    use Ash.Resource,
      domain: AshA2A.Chicago.Fixtures.EnvelopeNegotiationTransport.CatalogDomain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshA2A]

    attributes do
      uuid_primary_key(:id)
      attribute(:title, :string, public?: true)
    end

    actions do
      defaults([:read])
    end

    a2a do
      skill(:browse_catalog, :read)
    end
  end

  defmodule CatalogDomain do
    @moduledoc "Domain for `Catalog`."
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(AshA2A.Chicago.Fixtures.EnvelopeNegotiationTransport.Catalog)
    end
  end

  defmodule OrderingAgent do
    @moduledoc "Real `AshA2A.Agent` GenServer over `Ordering` (CommandBus on `:place_order`)."

    use AshA2A.Agent,
      resource_or_domain: AshA2A.Chicago.Fixtures.EnvelopeNegotiationTransport.Ordering,
      name: "chicago_ordering_agent"
  end

  defmodule SemanticPeerAgent do
    @moduledoc """
    Real `A2A.Agent` GenServer whose `handle_message/2` runs the real
    `AshA2A.Semantic.Peer` boundary. Its reply is a projection of the real
    outcome, never an independent claim.

    The peer configuration is keyed in `:persistent_term` by the process's
    registered name, because `use A2A.Agent`'s generated `start_link/1` owns
    the GenServer's init arguments.
    """

    use A2A.Agent,
      name: "chicago_semantic_peer",
      description: "Semantic A2A receiving peer under Chicago qualification.",
      skills: [
        %{
          id: "sa2a.admit",
          name: "admit",
          description: "Runs this peer's own admission over a candidate envelope.",
          tags: ["semantic", "admission"]
        }
      ]

    alias AshA2A.Semantic.Peer

    @doc "Installs the real peer configuration for a registered agent name."
    @spec configure(atom(), keyword()) :: :ok
    def configure(agent_name, opts),
      do: :persistent_term.put({__MODULE__, agent_name}, Peer.new(opts))

    @doc "Removes a peer configuration."
    @spec deconfigure(atom()) :: :ok
    def deconfigure(agent_name) do
      :persistent_term.erase({__MODULE__, agent_name})
      :ok
    end

    @doc false
    def __sa2a_refusal_codes__, do: %{peer_not_configured: :blocked_resource}

    @impl A2A.Agent
    def handle_message(message, _context) do
      {:registered_name, name} = Process.info(self(), :registered_name)

      case :persistent_term.get({__MODULE__, name}, nil) do
        nil ->
          {:error, :peer_not_configured}

        peer ->
          outcome = Peer.receive_message(peer, message)

          payload =
            outcome
            |> Map.take([:standing, :envelope_id, :graph_digest, :code])
            |> Enum.reject(fn {_k, v} -> is_nil(v) end)
            |> Map.new(fn {k, v} ->
              {Atom.to_string(k), if(is_atom(v), do: Atom.to_string(v), else: v)}
            end)

          {:reply, [A2A.Part.Data.new(payload)]}
      end
    end
  end

  defmodule Endpoint do
    @moduledoc """
    Real Plug endpoint: optional real `A2A.Plug.Auth` (bearer tokens resolved
    to verified identities), then the real `A2A.Plug`.

    Options: `:agent` (required), `:advertise` (`:compatible` | `:none` |
    `{:version, v}`), `:tokens` (`%{token => identity}`; omit for no auth).
    The base URL is taken from the request, so the served card names the
    listener that actually served it.
    """

    @behaviour Plug

    alias AshA2A.Semantic.Extension

    @impl Plug
    def init(opts) do
      auth =
        case Keyword.get(opts, :tokens) do
          nil ->
            nil

          tokens ->
            A2A.Plug.Auth.init(
              schemes: %{"bearer_auth" => %A2A.SecurityScheme.HTTPAuth{scheme: "bearer"}},
              verify: fn "bearer_auth", token, _conn ->
                case Map.fetch(tokens, token) do
                  {:ok, identity} -> {:ok, identity}
                  :error -> {:error, "unknown bearer token"}
                end
              end
            )
        end

      %{
        agent: Keyword.fetch!(opts, :agent),
        advertise: Keyword.get(opts, :advertise, :none),
        auth: auth
      }
    end

    @impl Plug
    def call(conn, %{agent: agent, advertise: advertise, auth: auth}) do
      base_url = "#{conn.scheme}://#{conn.host}:#{conn.port}"
      conn = if auth, do: A2A.Plug.Auth.call(conn, auth), else: conn

      if conn.halted do
        conn
      else
        A2A.Plug.call(
          conn,
          A2A.Plug.init(
            agent: agent,
            base_url: base_url,
            agent_card_opts: card_opts(advertise, base_url)
          )
        )
      end
    end

    @doc "Agent-card encoder options for an advertisement mode."
    @spec card_opts(:compatible | :none | {:version, String.t()}, String.t()) :: keyword()
    def card_opts(:none, _url), do: []
    def card_opts(:compatible, url), do: Extension.advertise(url: url)

    def card_opts({:version, version}, url) do
      [
        supported_interfaces: [
          %{url: url, protocol_binding: "JSONRPC", protocol_version: "0.3.0"},
          %{url: url, protocol_binding: Extension.profile_id(), protocol_version: version}
        ]
      ]
    end
  end

  defmodule Http do
    @moduledoc """
    The two real bindings' plumbing: an in-process `Plug` pipeline
    (`Plug.Test` through the real `Endpoint`) and a real local Bandit
    listener. Bandit is resolved at runtime (it is a test-env dependency) so
    this module compiles in every environment.
    """

    alias AshA2A.Chicago.Fixtures.EnvelopeNegotiationTransport.Endpoint

    @doc "True when a real Bandit listener can be started in this runtime."
    @spec bandit_available?() :: boolean()
    def bandit_available?, do: Code.ensure_loaded?(bandit()) and Code.ensure_loaded?(island())

    @doc "Starts a real Bandit listener on 127.0.0.1 with an ephemeral port."
    @spec start_listener(keyword()) :: {:ok, %{pid: pid(), url: String.t()}} | {:error, term()}
    def start_listener(endpoint_opts) do
      bandit_opts = [
        plug: {Endpoint, endpoint_opts},
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      ]

      with {:ok, pid} <- apply(bandit(), :start_link, [bandit_opts]),
           {:ok, {_ip, port}} <- apply(island(), :listener_info, [pid]) do
        {:ok, %{pid: pid, url: "http://127.0.0.1:#{port}"}}
      end
    end

    @doc "Stops a listener started by `start_listener/1`."
    @spec stop_listener(%{pid: pid()}) :: :ok
    def stop_listener(%{pid: pid}) do
      if Process.alive?(pid), do: Supervisor.stop(pid, :normal)
      :ok
    end

    @doc "GETs the agent card through the real Plug pipeline and decodes it."
    @spec served_card(keyword()) :: {:ok, A2A.AgentCard.t(), map()} | {:error, term()}
    def served_card(endpoint_opts) do
      conn =
        :get
        |> Plug.Test.conn("http://peer.local:4000/.well-known/agent-card.json")
        |> Endpoint.call(Endpoint.init(endpoint_opts))

      with 200 <- conn.status,
           {:ok, json} <- Jason.decode(conn.resp_body),
           {:ok, card} <- A2A.JSON.decode_agent_card(json) do
        {:ok, card, json}
      else
        other -> {:error, {:agent_card_not_served, other}}
      end
    end

    @doc """
    POSTs a real JSON-RPC `message/send` through the real Plug pipeline
    in-process. Returns the decoded JSON-RPC response body.
    """
    @spec post_message(keyword(), A2A.Message.t(), keyword()) :: {integer(), map()}
    def post_message(endpoint_opts, %A2A.Message{} = message, opts \\ []) do
      {:ok, encoded} = A2A.JSON.encode(message)

      params =
        case Keyword.get(opts, :metadata) do
          nil -> %{"message" => encoded}
          metadata -> %{"message" => encoded, "metadata" => metadata}
        end

      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => System.unique_integer([:positive]),
          "method" => "message/send",
          "params" => params
        })

      conn =
        Enum.reduce(
          Keyword.get(opts, :headers, []),
          Plug.Test.conn(:post, "http://peer.local:4000/", body),
          fn {k, v}, conn -> Plug.Conn.put_req_header(conn, k, v) end
        )
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Endpoint.call(Endpoint.init(endpoint_opts))

      {conn.status, Jason.decode!(conn.resp_body)}
    end

    @doc "The first `Part.Data` payload of a completed task's first artifact."
    @spec reply_data(A2A.Task.t() | map()) :: map() | nil
    def reply_data(%A2A.Task{artifacts: [%A2A.Artifact{parts: parts} | _]}),
      do:
        Enum.find_value(parts, fn
          %A2A.Part.Data{data: data} -> data
          _ -> nil
        end)

    def reply_data(%{"result" => %{"task" => %{"artifacts" => [%{"parts" => parts} | _]}}}),
      do: Enum.find_value(parts, &Map.get(&1, "data"))

    def reply_data(_), do: nil

    defp bandit, do: Module.concat([Bandit])
    defp island, do: Module.concat([ThousandIsland])
  end
end
