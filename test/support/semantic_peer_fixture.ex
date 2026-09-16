defmodule AshA2A.Test.SemanticPeerFixture.Ordering do
  @moduledoc """
  Real `Ash.Resource` behind peer B's capability surface, used by
  `test/ash_a2a_semantic_agent_card_test.exs` and the cross-peer test.

  Deliberately carries both a non-consequence-bearing `:read` and
  consequence-bearing `:create`/`:destroy` actions, so
  `AshA2A.Semantic.AgentCard` has real `:observe` and real `:change`
  capabilities to derive from instead of a single-shaped surface that would
  hide the authority/receipt split.
  """

  use Ash.Resource,
    domain: AshA2A.Test.SemanticPeerFixture.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:item, :string, public?: true)
    attribute(:quantity, :integer, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: [:item, :quantity]])
  end

  a2a do
    skill :place_order, :create do
      hddl_operator do
        parameters([:order, :item])
        preconditions([{:available, [:item]}])
        add_effects([{:ordered, [:order]}])
        delete_effects([{:available, [:item]}])
      end
    end
  end
end

defmodule AshA2A.Test.SemanticPeerFixture.Domain do
  @moduledoc """
  Real domain pairing `AshA2A.Test.SemanticPeerFixture.Ordering`, giving
  `AshA2A.Info.capability_index/1` a real compiled index for the semantic
  agent-card derivation tests.
  """

  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2A.Test.SemanticPeerFixture.Ordering)
  end
end

defmodule AshA2A.Test.SemanticPeerFixture.PeerB do
  @moduledoc """
  Real `A2A.Agent` GenServer standing in for a remote Semantic A2A peer.

  This is peer B in `Message_A -> Candidate_B -> GraphLaw_B -> O*_B`. It is
  a genuine `use A2A.Agent` process fronted by a genuine `A2A.Plug`, and its
  `handle_message/2` runs the real `AshA2A.Semantic.Peer` boundary against
  its **own** shapes and its **own** `AshA2A.Semantic.GraphLaw` engine.

  It is not a mock. Nothing here fakes a collaborator: the engine it calls is
  the real prebuilt `praxis-graphlaw` wasm, the ledger it writes is a real
  supervised process, and the reply it sends is derived from the real
  outcome rather than scripted.

  Configuration reaches it through `:persistent_term` keyed by the agent's
  registered name, because `use A2A.Agent`'s generated `start_link/1` owns
  the GenServer's own init arguments. Each test writes its own key and
  deletes it on exit.
  """

  use A2A.Agent,
    name: "sa2a_peer_b",
    description: "Semantic A2A peer B: admits nothing it did not itself check.",
    skills: [
      %{
        id: "sa2a.admit",
        name: "admit",
        description: "Runs this peer's own GraphLaw admission over a candidate envelope.",
        tags: ["semantic", "admission"]
      }
    ]

  alias AshA2A.Semantic.{Extension, Peer}

  @doc "Installs a real peer configuration for the named agent process."
  @spec configure(atom(), keyword()) :: :ok
  def configure(agent_name, opts) do
    :persistent_term.put({__MODULE__, agent_name}, Peer.new(opts))
  end

  @doc "Removes a peer configuration."
  @spec deconfigure(atom()) :: :ok
  def deconfigure(agent_name) do
    :persistent_term.erase({__MODULE__, agent_name})
    :ok
  end

  @doc "The real peer configuration currently installed for a process name."
  @spec peer(atom()) :: Peer.t()
  def peer(agent_name), do: :persistent_term.get({__MODULE__, agent_name})

  @impl A2A.Agent
  def handle_message(message, _context) do
    peer_name = registered_name()

    case :persistent_term.get({__MODULE__, peer_name}, nil) do
      nil ->
        {:error, :peer_not_configured}

      peer ->
        consequence_bearing? = consequence_bearing?(message)
        outcome = Peer.receive_message(peer, message, consequence_bearing?: consequence_bearing?)
        reply(outcome)
    end
  end

  # The reply is a projection of the real outcome, never an independent
  # claim. A test that only read this reply would still be reading the
  # peer's own words -- which is why the cross-peer test asserts on the
  # ledger too.
  defp reply(outcome) do
    payload =
      outcome
      |> Map.take([:standing, :envelope_id, :graph_digest, :code, :detail, :over_claimed])
      |> Map.new(fn {k, v} -> {to_string(k), stringify(v)} end)
      |> Map.put("unexercised", Enum.map(Map.get(outcome, :unexercised, []), &stringify/1))

    parts = [A2A.Part.Data.new(payload)]

    case outcome.standing do
      :admitted -> {:reply, parts}
      _ -> {:reply, parts}
    end
  end

  defp stringify(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: to_string(value)

  defp stringify(%{} = value),
    do: Map.new(value, fn {k, v} -> {to_string(k), stringify(v)} end)

  defp stringify(value), do: value

  # S76 input: whether the *requested* task would bear a consequence. Taken
  # from the message's own declared consequence class where the profile was
  # activated, and from an explicit metadata flag otherwise -- a
  # non-Semantic peer has no envelope to read it from.
  defp consequence_bearing?(%A2A.Message{} = message) do
    cond do
      Extension.activated?(message) ->
        case Extension.payload(message) do
          {:ok, %{"consequenceClass" => class}} -> class in ["change", "external_do"]
          _ -> false
        end

      true ->
        Map.get(message.metadata, "consequenceBearing") == true
    end
  end

  defp registered_name do
    case Process.info(self(), :registered_name) do
      {:registered_name, name} when is_atom(name) -> name
      _ -> nil
    end
  end
end

defmodule AshA2A.Test.SemanticPeerFixture.Graphs do
  @moduledoc """
  Real Turtle fixtures and real SHACL shapes for the cross-peer tests.

  Peer B's shapes are peer B's own: peer A never sends shapes, and peer B
  never uses any it received. That asymmetry is the point of the whole
  boundary, so it is expressed here as two separate functions rather than
  one shared constant.
  """

  @doc "A conforming order graph peer A might send."
  @spec conforming_order() :: String.t()
  def conforming_order do
    """
    @prefix ex: <http://example.org/> .
    ex:order-1 a ex:Order ;
      ex:item "widget" ;
      ex:quantity 3 .
    """
  end

  @doc """
  The same order graph, reordered and with a different prefix label.

  Semantically identical to `conforming_order/0`. Used to show the engine's
  canonical graph identity: both must hash to the same value even though the
  bytes differ.
  """
  @spec conforming_order_reordered() :: String.t()
  def conforming_order_reordered do
    """
    @prefix zz: <http://example.org/> .
    zz:order-1 zz:quantity 3 .
    zz:order-1 zz:item "widget" .
    zz:order-1 a zz:Order .
    """
  end

  @doc "An order graph missing the property peer B's shapes require."
  @spec nonconforming_order() :: String.t()
  def nonconforming_order do
    """
    @prefix ex: <http://example.org/> .
    ex:order-1 a ex:Order ;
      ex:quantity 3 .
    """
  end

  @doc "Peer B's own SHACL shapes. Never supplied by a sender."
  @spec peer_b_shapes() :: String.t()
  def peer_b_shapes do
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
