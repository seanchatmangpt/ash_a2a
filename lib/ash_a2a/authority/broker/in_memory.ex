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
    # `issued` is a MAP (key -> `%{expires_at:, binding:}`), not a `MapSet`.
    # A set can only record THAT a grant was issued, never UNTIL WHEN or FOR
    # WHOM -- which is exactly how (a) an expired grant was still authorizing
    # a real `:external_do` actuation (`granted?/3` consulted only set
    # membership) and (b) a rebound authority (same token id, rewritten
    # `subject`) verified cleanly. Both pieces of state are needed by
    # different real callers below, so both are stored together per key.
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
    status = GenServer.call(server(opts), {:grant_status, key})
    AshA2A.Authority.Broker.emit_lookup(__MODULE__, subject, capability_id, status) == :standing
  catch
    :exit, _reason ->
      AshA2A.Authority.Broker.emit_lookup(__MODULE__, subject, capability_id, :unavailable)
      false
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

  @impl AshA2A.Authority.Broker
  @spec list_grants(Identity.t(), keyword()) ::
          {:ok, [AshA2A.Authority.Broker.grant_entry()]} | :error
  def list_grants(%Identity{kind: :principal} = subject, opts \\ []) do
    GenServer.call(server(opts), {:list_grants, Identity.external(subject)})
  catch
    :exit, _reason -> :error
  end

  @impl AshA2A.Authority.Broker
  @spec renew(Identity.t(), String.t(), DateTime.t() | nil, keyword()) ::
          :ok | {:error, AshA2A.Authority.Broker.refusal()}
  def renew(%Identity{kind: :principal} = subject, capability_id, new_expires_at, opts \\ [])
      when is_binary(capability_id) do
    key = Identity.external(Identity.runtime(Authority.grant_token_id(subject, capability_id)))
    GenServer.call(server(opts), {:renew, key, new_expires_at})
  catch
    :exit, _reason -> {:error, %{reason: :broker_unavailable}}
  end

  @impl GenServer
  def handle_call({:issue, subject, capability_id, opts}, _from, state) do
    authority =
      Authority.new(subject, capability_id, Keyword.put_new(opts, :source, :authority_broker))

    key = Identity.external(authority.token_id)

    if Map.has_key?(state.issued, key) do
      {:reply, {:error, %{reason: :token_id_taken, token_id: authority.token_id}}, state}
    else
      entry = %{expires_at: authority.expires_at, binding: token_binding(authority)}
      {:reply, {:ok, authority}, %{state | issued: Map.put(state.issued, key, entry)}}
    end
  end

  def handle_call({:revoke, %Authority{} = authority}, _from, state) do
    key = Identity.external(authority.token_id)
    {:reply, :ok, %{state | revoked: MapSet.put(state.revoked, key)}}
  end

  def handle_call({:grant_status, key}, _from, state) do
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
    {:reply, grant_status(state, key), state}
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
            issued_binding: Map.fetch!(state.issued, key).binding,
            presented_binding: token_binding(authority)
          }}, state}

      true ->
        {:reply, {:ok, authority}, state}
    end
  end

  def handle_call({:grant_expires_at, key}, _from, state) do
    reply =
      if standing?(state, key),
        do: {:ok, Map.fetch!(state.issued, key).expires_at},
        else: :error

    {:reply, reply, state}
  end

  def handle_call({:list_grants, subject_external}, _from, state) do
    # A pure read of the exact `issued`/`revoked` state `handle_call({:issue,
    # ...})` and `handle_call({:revoke, ...})` above already maintain -- this
    # clause records nothing, matching the `{:grant_status, ...}` and
    # `{:grant_expires_at, ...}` clauses above it. `entry.binding` already
    # carries `{subject_external, capability_id}` (see `token_binding/1`), so
    # no additional per-entry state is needed to answer "every capability
    # this subject holds a standing grant for".
    grants =
      state.issued
      |> Enum.filter(fn {key, %{binding: {bound_subject, _capability_id}}} ->
        bound_subject == subject_external and standing?(state, key)
      end)
      |> Enum.map(fn {_key, %{binding: {_subject, capability_id}, expires_at: expires_at}} ->
        %{capability_id: capability_id, expires_at: expires_at}
      end)

    {:reply, {:ok, grants}, state}
  end

  def handle_call({:renew, key, new_expires_at}, _from, state) do
    # `renew/4`'s own contract: only a grant that is STANDING right now (not
    # absent, not revoked, not already expired) may have its `expires_at`
    # rewritten -- `grant_status/2` is the exact same read `granted?/3`
    # already uses, so "renewable" and "currently granted" never diverge.
    case grant_status(state, key) do
      :standing ->
        entry = Map.fetch!(state.issued, key)
        updated = %{entry | expires_at: new_expires_at}
        {:reply, :ok, %{state | issued: Map.put(state.issued, key, updated)}}

      other ->
        {:reply, {:error, %{reason: :grant_not_standing, status: other}}, state}
    end
  end

  # A grant stands only if it was issued, has not been revoked, AND has not
  # expired. `expires_at: nil` means "no time bound", which is what
  # `Authority.new/3` produces when no `:expires_at` is supplied.
  defp standing?(state, key), do: grant_status(state, key) == :standing

  defp grant_status(state, key) do
    case Map.fetch(state.issued, key) do
      :error -> :absent
      {:ok, entry} -> entry_status(MapSet.member?(state.revoked, key), entry.expires_at)
    end
  end

  defp entry_status(true = _revoked, _expires_at), do: :revoked
  defp entry_status(false, expires_at), do: if(past?(expires_at), do: :expired, else: :standing)

  defp past?(nil), do: false

  defp past?(%DateTime{} = expires_at),
    do: DateTime.compare(DateTime.utc_now(), expires_at) != :lt

  # An `expires_at` this module cannot interpret is an unanswerable grant
  # question, and an unanswerable grant question is a refusal, never an
  # admission -- so an unrecognized term is treated as already past.
  defp past?(_other), do: true

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
      {:ok, entry} -> entry.binding != token_binding(authority)
      :error -> false
    end
  end

  defp token_binding(%Authority{} = authority),
    do: {Identity.external(authority.subject), authority.capability_id}

  defp server(opts), do: Keyword.get(opts, :name, __MODULE__)
end
