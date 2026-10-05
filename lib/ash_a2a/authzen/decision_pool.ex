# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.AuthZEN.DecisionPool do
  @moduledoc """
  Real HTTP connection pool and local TTL decision cache for AuthZEN PDP
  evaluation. `post/4` runs the actual POST to the PDP through a named
  `Finch` pool; `cache_get/3` and `cache_put/4` provide local decision
  caching with a configured TTL.

  The pool process is a GenServer that owns the Finch pool and the ETS
  cache table. `child_spec/1` is provided so operators can run it under
  their own supervision tree; `ensure_started/0` lazily starts it (unlinked,
  temporary) when no supervisor owns it, so a bare evaluation call still
  has a real pool behind it. If the process dies, the cache dies with it
  and the next `ensure_started/0` rebuilds both — the failure mode is a
  cache miss, never a stale allow.
  """

  use GenServer

  @finch Module.concat(__MODULE__, "Finch")
  @table Module.concat(__MODULE__, "Cache")
  @default_timeout 5_000

  @doc "Supervision child spec: one GenServer owning one Finch pool and the ETS cache."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Lazily starts the pool if it is not already running. Unlinked
  (`GenServer.start/3`): the pool outlives the calling process. Returns
  `:ok` when the pool is (now) already running or a typed error otherwise.
  """
  @spec ensure_started(keyword()) :: :ok | {:error, term()}
  def ensure_started(opts \\ []) do
    case GenServer.whereis(__MODULE__) do
      nil ->
        case GenServer.start(__MODULE__, opts, name: __MODULE__) do
          {:ok, _pid} -> :ok
          {:error, :normal} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      pid when is_pid(pid) ->
        :ok
    end
  end

  @doc """
  Runs the real POST to the PDP endpoint through the named Finch pool.
  Transport failure or timeout collapses to the typed `{:error,
  :pdp_unreachable}` fail-closed refusal; non-2xx collapses to
  `{:error, {:pdp_error, status}}`. Returns `{:ok, status, body}` on 2xx.
  """
  @spec post(String.t(), iodata(), [{String.t(), String.t()}], keyword()) ::
          {:ok, pos_integer(), binary()}
          | {:error, :pdp_unreachable}
          | {:error, {:pdp_error, pos_integer()}}
  def post(url, body, headers, opts \\ []) do
    request = Finch.build(:post, url, headers, body)
    timeout = Keyword.get(opts, :receive_timeout, @default_timeout)

    case Finch.request(request, @finch, receive_timeout: timeout) do
      {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, status, body}

      {:ok, %Finch.Response{status: status}} ->
        {:error, {:pdp_error, status}}

      {:error, _exception} ->
        {:error, :pdp_unreachable}
    end
  end

  @doc """
  Reads a cached decision for `{endpoint, encoded_request}` that has not
  passed its TTL. Returns `{:ok, decision}` (the cached
  `%AshA2A.AuthZEN.Types.Decision{}`), `:miss`, or `:expired`.
  """
  @spec cache_get(String.t(), iodata(), integer()) ::
          {:ok, AshA2A.AuthZEN.Types.Decision.t()} | :miss | :expired
  def cache_get(endpoint, encoded_request, now_ms) do
    key = cache_key(endpoint, encoded_request)

    case :ets.lookup(@table, key) do
      [{_key, {decision, expires_at}}] when is_integer(expires_at) ->
        if expires_at > now_ms, do: {:ok, decision}, else: :expired

      _ ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc """
  Stores a decision under `{endpoint, encoded_request}` until `now_ms +
  ttl_ms`. `ttl_ms <= 0` writes nothing (dead entries are never stored),
  and a cold table degrades to `false` (write lost, next read is a miss) —
  both failure modes are cache misses, never stale allows.
  """
  @spec cache_put(String.t(), iodata(), AshA2A.AuthZEN.Types.Decision.t(), keyword()) :: boolean()
  def cache_put(endpoint, encoded_request, decision, opts) do
    now_ms = Keyword.fetch!(opts, :now_ms)
    ttl_ms = Keyword.fetch!(opts, :ttl_ms)

    if is_integer(ttl_ms) and ttl_ms > 0 do
      :ets.insert(@table, {cache_key(endpoint, encoded_request), {decision, now_ms + ttl_ms}})
      true
    else
      false
    end
  rescue
    ArgumentError -> false
  end

  @doc "Drops all cached decisions. Real invalidation witness for tests and operators."
  @spec cache_clear() :: :ok
  def cache_clear do
    if :ets.whereis(@table) == :undefined do
      :ok
    else
      :ets.delete_all_objects(@table)
      :ok
    end
  end

  @impl GenServer
  def init(_opts) do
    {:ok, _finch_pid} =
      Finch.start_link(
        name: @finch,
        pools: %{default: [protocols: [:http1], conn_opts: [protocols: [:http1]]]}
      )

    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

    {:ok, %{}}
  end

  defp cache_key(endpoint, encoded_request) do
    :crypto.hash(:sha256, endpoint <> ":" <> IO.iodata_to_binary(encoded_request))
  end
end
