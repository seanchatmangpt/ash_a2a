defmodule AshA2A.Chicago.Courts.SemanticBoundary do
  @moduledoc """
  Shared, non-court plumbing for the RFC-SA2A-002 §54/§55/§56/§75 courts.

  ## OCEL interpretation of the Semantic A2A boundary

  `AshA2A.Semantic.Peer` emits `[:ash_a2a, :semantic, :peer, :receive |
  [:admission, :start] | :decision]` at its own decision points. Each court
  admits its OWN mapping of those events under a court-scoped activity prefix
  (`"sa2a.env"`, `"sa2a.neg"`, `"sa2a.transport"`), sourced from the court
  module. That keeps each court self-contained (a court run alone still
  observes the boundary it attacks) without double-counting when several
  courts run together: a court's predicates only ever name its own prefix.

  Object types:

    * `sa2a_peer` -- the receiving peer's name
    * `a2a_message` -- the inbound A2A message id
    * `sa2a_envelope` -- the envelope id the peer decided about
    * `sa2a_outcome` -- the transport-invariant semantic outcome: a digest of
      `(envelope_id, standing, code, graph_digest)` computed from what the
      peer emitted. Two decisions relate to the same `sa2a_outcome` object
      iff they decided the same thing about the same envelope, which is what
      `{:distinct_objects, activity, "sa2a_outcome", op, n}` asks.
  """

  alias AshA2A.Chicago.{Context, Falsifier}
  alias AshA2A.Chicago.Fixtures.EnvelopeNegotiationTransport.{Http, SemanticPeerAgent}
  alias AshA2A.Chicago.Ocel.Mapping
  alias AshA2A.Semantic.Standing.Ledger

  @doc "Court-scoped OCEL mappings for the peer boundary events."
  @spec peer_mappings(String.t(), module()) :: [Mapping.t()]
  def peer_mappings(prefix, source) do
    [
      Mapping.new!(
        event: [:ash_a2a, :semantic, :peer, :receive],
        activity: prefix <> ".receive",
        source: source,
        objects: fn _m, meta ->
          [
            {"sa2a_peer", meta[:peer], "peer"},
            {"a2a_message", meta[:message_id], "message"}
          ]
        end,
        attributes: fn _m, meta -> Map.take(meta, [:activated, :mode]) end
      ),
      Mapping.new!(
        event: [:ash_a2a, :semantic, :peer, :admission, :start],
        activity: prefix <> ".admission.start",
        source: source,
        objects: fn _m, meta ->
          [
            {"sa2a_peer", meta[:peer], "peer"},
            {"sa2a_envelope", meta[:envelope_id], "envelope"}
          ]
        end,
        attributes: fn _m, meta ->
          Map.take(meta, [:standing, :profile, :consequence_class, :authority_requirement])
        end
      ),
      Mapping.new!(
        event: [:ash_a2a, :semantic, :peer, :decision],
        activity: prefix <> ".decision",
        source: source,
        objects: fn _m, meta ->
          [
            {"sa2a_peer", meta[:peer], "peer"},
            {"sa2a_envelope", meta[:envelope_id], "envelope"},
            {"sa2a_outcome", outcome_id(meta), "outcome"}
          ]
        end,
        attributes: fn _m, meta ->
          Map.take(meta, [:path, :mode, :standing, :code, :class, :graph_digest])
        end
      )
    ]
  end

  @doc "Transport-invariant outcome identity of one peer decision."
  @spec outcome_id(map()) :: String.t()
  def outcome_id(meta) do
    [meta[:envelope_id], meta[:standing], meta[:code], meta[:graph_digest]]
    |> Enum.map_join("|", &to_string/1)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Starts a real `Standing.Ledger` and a real `SemanticPeerAgent`, installs the
  peer configuration built by `config_fun.(agent_name, ledger_name)`, runs
  `fun.(%{agent: name, ledger: name})`, and tears everything down.
  """
  @spec with_peer(String.t(), (atom(), atom() -> keyword()), (map() -> result)) :: result
        when result: var
  def with_peer(label, config_fun, fun) do
    suffix = System.unique_integer([:positive])
    agent = :"chicago_#{label}_peer_#{suffix}"
    ledger = :"chicago_#{label}_ledger_#{suffix}"
    {:ok, ledger_pid} = Ledger.start_link(name: ledger)
    {:ok, agent_pid} = SemanticPeerAgent.start_link(name: agent)

    try do
      :ok = SemanticPeerAgent.configure(agent, config_fun.(agent, ledger))
      fun.(%{agent: agent, ledger: ledger})
    after
      SemanticPeerAgent.deconfigure(agent)
      stop(agent_pid)
      stop(ledger_pid)
    end
  end

  @doc "Stops a linked process without taking the caller down."
  @spec stop(pid()) :: :ok
  def stop(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  @doc "The agent card the real Plug pipeline serves for `agent` (decoded)."
  @spec served_card!(atom(), :compatible | :none | {:version, String.t()}) :: A2A.AgentCard.t()
  def served_card!(agent, advertise) do
    {:ok, card, _json} = Http.served_card(agent: agent, advertise: advertise)
    card
  end

  @doc "In-process A2A binding: a real `A2A.call/3` into the agent GenServer."
  @spec call(atom(), A2A.Message.t(), keyword()) :: map() | {:error, term()}
  def call(agent, message, opts \\ []) do
    case A2A.call(agent, message, opts) do
      {:ok, task} -> Http.reply_data(task) || %{"task_state" => to_string(task.status.state)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Observer records of `activity` attributed to `falsifier` whose attributes include `attrs`."
  @spec observed(Context.t(), Falsifier.t(), String.t(), map()) :: [map()]
  def observed(%Context{} = ctx, %Falsifier{} = f, activity, attrs \\ %{}) do
    ctx
    |> Context.observed(f)
    |> Enum.filter(fn record ->
      record.activity == activity and
        Enum.all?(attrs, fn {k, v} ->
          to_string(Map.get(record.attributes, to_string(k))) == to_string(v)
        end)
    end)
  end

  @doc "True when at least one matching record was observed."
  @spec observed?(Context.t(), Falsifier.t(), String.t(), map()) :: boolean()
  def observed?(ctx, f, activity, attrs \\ %{}), do: observed(ctx, f, activity, attrs) != []

  @doc "Ledger entries appended after `before` (an earlier `Ledger.entries/1` snapshot)."
  @spec new_entries(atom(), [map()]) :: [map()]
  def new_entries(ledger, before), do: Enum.drop(Ledger.entries(ledger), length(before))

  @doc "Stringifies a reply for JSON-safe evidence."
  @spec evidence(term()) :: String.t() | map()
  def evidence(%{} = map), do: map
  def evidence(other), do: inspect(other, limit: 20)
end
