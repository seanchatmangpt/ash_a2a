defmodule AshA2A.Authority.Broker.InMemory do
  @moduledoc """
  Single-node, in-process reference implementation of
  `AshA2A.Authority.Broker`, backed by a real `GenServer` (real process
  state -- issued and revoked token ids live in that process's own state,
  not in a hidden global or an ETS table shared across callers).

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
    # `issued` is a MAP (key -> `expires_at`), not a `MapSet`. A set can only
    # record THAT a grant was issued, never UNTIL WHEN -- which is exactly how
    # an expired grant was still authorizing a real `:external_do` actuation
    # (`granted?/3` consulted only set membership, while this module's own
    # `verify/2` correctly checked `Authority.expired?/1`). The grant's
    # `expires_at` has to be stored to be enforceable, so it is stored.
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

  @impl AshA2A.Authority.Broker
  @spec granted?(Identity.t(), String.t(), keyword()) :: boolean()
  def granted?(%Identity{kind: :principal} = subject, capability_id, opts \\ [])
      when is_binary(capability_id) do
    key = Identity.external(Identity.runtime(Authority.grant_token_id(subject, capability_id)))

    # Fails closed on a broker process that is not running (or has died):
    # `GenServer.call/2` exits, and an unanswerable grant question is a
    # refusal, never an admission.
    GenServer.call(server(opts), {:granted?, key})
  catch
    :exit, _reason -> false
  end

  @impl AshA2A.Authority.Broker
  @spec grant_expires_at(Identity.t(), String.t(), keyword()) ::
          {:ok, DateTime.t() | nil} | :error
  def grant_expires_at(%Identity{kind: :principal} = subject, capability_id, opts \\ [])
      when is_binary(capability_id) do
    key = Identity.external(Identity.runtime(Authority.grant_token_id(subject, capability_id)))
    GenServer.call(server(opts), {:grant_expires_at, key})
  catch
    :exit, _reason -> :error
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
       %{state | issued: Map.put(state.issued, key, authority.expires_at)}}
    end
  end

  def handle_call({:revoke, %Authority{} = authority}, _from, state) do
    key = Identity.external(authority.token_id)
    {:reply, :ok, %{state | revoked: MapSet.put(state.revoked, key)}}
  end

  def handle_call({:granted?, key}, _from, state) do
    # A pure read of the exact `issued`/`revoked` state `handle_call({:issue,
    # ...})` and `handle_call({:revoke, ...})` above already maintain -- this
    # clause records nothing.
    #
    # Expiry is checked HERE, not only in `verify/2`: `granted?/3` is the only
    # callback the real dispatch path asks
    # (`AshA2A.Authority.Grant.authorize/3`), so an expiry honoured only by
    # `verify/2` is an expiry never enforced on a real request. The behaviour's
    # own contract already said this clause answers whether a grant stands
    # "right now" and "must FAIL CLOSED" -- a grant whose `expires_at` has
    # passed does not stand right now.
    {:reply, standing?(state, key), state}
  end

  def handle_call({:verify, %Authority{} = authority}, _from, state) do
    key = Identity.external(authority.token_id)

    cond do
      Authority.expired?(authority) ->
        {:reply, {:error, %{reason: :expired, token_id: authority.token_id}}, state}

      MapSet.member?(state.revoked, key) ->
        {:reply, {:error, %{reason: :revoked, token_id: authority.token_id}}, state}

      true ->
        {:reply, {:ok, authority}, state}
    end
  end

  def handle_call({:grant_expires_at, key}, _from, state) do
    reply = if standing?(state, key), do: {:ok, Map.get(state.issued, key)}, else: :error
    {:reply, reply, state}
  end

  # A grant stands only if it was issued, has not been revoked, AND has not
  # expired. `expires_at: nil` means "no time bound", which is what
  # `Authority.new/3` produces when no `:expires_at` is supplied.
  defp standing?(state, key) do
    Map.has_key?(state.issued, key) and
      not MapSet.member?(state.revoked, key) and
      not past?(Map.get(state.issued, key))
  end

  defp past?(nil), do: false

  defp past?(%DateTime{} = expires_at),
    do: DateTime.compare(DateTime.utc_now(), expires_at) != :lt

  # An `expires_at` this module cannot interpret is an unanswerable grant
  # question, and an unanswerable grant question is a refusal, never an
  # admission -- so an unrecognized term is treated as already past.
  defp past?(_other), do: true

  defp server(opts), do: Keyword.get(opts, :name, __MODULE__)
end
