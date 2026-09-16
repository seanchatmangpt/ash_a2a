defmodule AshA2A.Authority.Broker.InMemory do
  @moduledoc """
  Single-node, in-process reference implementation of
  `AshA2A.Authority.Broker`, backed by a real `GenServer` (real process
  state -- issued token bindings and revoked token ids live in that
  process's own state, not in a hidden global or an ETS table shared across
  callers).

  An issued token id is recorded together with the `(subject, capability_id)`
  pair it was issued for, so `verify/2` can refuse a token whose binding has
  since been rewritten (`reason: :token_binding_mismatch`) -- see the
  confused-deputy note on `rebound?/3` below for what that closes and what
  it deliberately does not.

  NOT Sybil-resistant. NOT distributed. This is a development/test
  fixture, not a production identity system: it has no notion of a
  principal being who they claim to be beyond whatever the caller already
  decided before invoking `issue/3`, and it has no way to detect one real
  actor presenting as many distinct principals. Sybil-resistant identity
  issuance across untrusted, decentralized participants is a genuinely
  unsolved, published-impossible-in-general problem (Douceur, "The Sybil
  Attack," IPTPS 2002) -- this module does not attempt it and would be
  wrong to claim it did. It exists to give `AshA2A.Authority.Broker` a
  real, runnable implementation to test the behaviour's contract against
  and to develop against locally, not to answer that open problem.

  A real production deployment implementing `AshA2A.Authority.Broker`
  against its own identity system (an existing auth service, a hardware
  root of trust, a federated principal store) replaces this module
  entirely; nothing in this codebase requires `InMemory` specifically --
  see `AshA2A.Authority.Broker`'s moduledoc for the behaviour contract.

  Accepts a `:name` option on every call (matching this codebase's
  existing named-process convention, e.g. `AshA2A.Semantic.PackageStore`
  and `AshA2A.ReceiptStore.Memory`) so more than one independently-started
  `InMemory` process can be used in the same test run without colliding on
  the default `__MODULE__` name or sharing revocation state.
  """
  use GenServer

  @behaviour AshA2A.Authority.Broker

  alias AshA2A.{Authority, Identity}

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{issued: %{}, revoked: MapSet.new()},
      name: Keyword.get(opts, :name, __MODULE__)
    )
  end

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl AshA2A.Authority.Broker
  @spec issue(Identity.t(), String.t(), keyword()) ::
          {:ok, Authority.t()} | {:error, AshA2A.Authority.Broker.refusal()}
  def issue(%Identity{kind: :principal} = subject, capability_id, opts \\ [])
      when is_binary(capability_id) do
    GenServer.call(server(opts), {:issue, subject, capability_id, opts})
  end

  @impl AshA2A.Authority.Broker
  @spec revoke(Authority.t(), keyword()) :: :ok | {:error, AshA2A.Authority.Broker.refusal()}
  def revoke(%Authority{} = authority, opts \\ []) do
    GenServer.call(server(opts), {:revoke, authority})
  end

  @impl AshA2A.Authority.Broker
  @spec verify(Authority.t(), keyword()) ::
          {:ok, Authority.t()} | {:error, AshA2A.Authority.Broker.refusal()}
  def verify(%Authority{} = authority, opts \\ []) do
    GenServer.call(server(opts), {:verify, authority})
  end

  @impl GenServer
  def handle_call({:issue, subject, capability_id, opts}, _from, state) do
    authority =
      Authority.new(subject, capability_id, Keyword.put_new(opts, :source, :authority_broker))

    key = Identity.external(authority.token_id)

    if Map.has_key?(state.issued, key) do
      {:reply, {:error, %{reason: :token_id_taken, token_id: authority.token_id}}, state}
    else
      {:reply, {:ok, authority},
       %{state | issued: Map.put(state.issued, key, token_binding(authority))}}
    end
  end

  def handle_call({:revoke, %Authority{} = authority}, _from, state) do
    key = Identity.external(authority.token_id)
    {:reply, :ok, %{state | revoked: MapSet.put(state.revoked, key)}}
  end

  def handle_call({:verify, %Authority{} = authority}, _from, state) do
    key = Identity.external(authority.token_id)

    cond do
      Authority.expired?(authority) ->
        {:reply, {:error, %{reason: :expired, token_id: authority.token_id}}, state}

      MapSet.member?(state.revoked, key) ->
        {:reply, {:error, %{reason: :revoked, token_id: authority.token_id}}, state}

      rebound?(state, key, authority) ->
        {:reply,
         {:error,
          %{
            reason: :token_binding_mismatch,
            token_id: authority.token_id,
            issued_binding: Map.fetch!(state.issued, key),
            presented_binding: token_binding(authority)
          }}, state}

      true ->
        {:reply, {:ok, authority}, state}
    end
  end

  # RFC-SA2A-001 S54 (confused deputy). A token id alone is not the grant:
  # what was issued is a (subject, capability) pair. If THIS broker issued
  # this token id, the presented authority must still carry the same subject
  # and capability -- otherwise a deputy could take a grant it legitimately
  # holds, rewrite `subject` to the peer that asked it for a favor, and have
  # the broker confirm the result. That was a real hole: before this clause
  # `verify/2` consulted only expiry and revocation, both keyed on
  # `token_id`, so `%{a_authority | subject: peer_b}` verified cleanly.
  #
  # Deliberately scoped to tokens this broker actually issued. A token id
  # this process has never seen still verifies (subject to expiry), which is
  # the existing, test-asserted behaviour that lets two independently-started
  # brokers hold independent revocation state -- see
  # `test/ash_a2a/authority_broker_in_memory_test.exs`. That remains a real
  # limitation of this development/test broker and is NOT closed here:
  # `InMemory` is not, and does not claim to be, a token-authenticity
  # oracle. `AshA2A.CommandBus` does not rely on it -- the bus binds
  # authority to the command's own principal via `AshA2A.Authority.admits?/2`
  # independently of any broker.
  defp rebound?(state, key, authority) do
    case Map.fetch(state.issued, key) do
      {:ok, issued} -> issued != token_binding(authority)
      :error -> false
    end
  end

  defp token_binding(%Authority{} = authority),
    do: {Identity.external(authority.subject), authority.capability_id}

  defp server(opts), do: Keyword.get(opts, :name, __MODULE__)
end
