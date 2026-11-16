defmodule AshA2A.Email.TokenLedgerStore do
  @moduledoc """
  Durable, cluster-wide replacement for `AshA2A.Email.TokenLedger`, backed by an
  `AshA2A.TaskStore.Ekv` (`EKV`) instance.

  It answers the same calls as `AshA2A.Email.TokenLedger` (`reserve`, `record_result`,
  `rate_check`), so the pid or registered name returned by `start_link/1` can be passed as the
  plug's `:token_ledger` unchanged; the plug itself is not modified.

      children = [
        AshA2A.TaskStore.Ekv.child_spec(name: MyApp.EmailKv, data_dir: "/var/lib/my_app/email"),
        {AshA2A.Email.TokenLedgerStore, name: MyApp.EmailLedger, store: MyApp.EmailKv}
      ]

  ## Guarantees

    * Each `(brief_id, n, token)` key is consumed with an insert-if-absent write
      (`if_vsn: nil`), which EKV makes atomic cluster-wide, so a token is single-use across nodes.
      Keys are stored as SHA-256 digests; raw reply tokens are never written to disk.
    * A reply's keys are consumed together: when any key is already taken, the keys this call
      inserted are deleted again and `{:error, :already_consumed}` is returned. An exact replay
      (same non-nil `message_id` consumed every key) returns `{:replay, cached_body | nil}`.
    * Entries survive restarts against the same `:data_dir`.
    * EKV failures or unconfirmed writes fail closed: `{:error, :ledger_unavailable}` (503 in
      the plug), never `:ok`.

  ## Limits (honest)

    * There is no capacity bound; entries are never evicted (eviction would re-open replay).
    * The rollback of a partially consumed reply is best-effort: if the node dies between insert
      and rollback, the orphaned keys stay consumed (fail closed, the approver must be reissued
      tokens).
    * `rate_check/4` is a node-local in-memory sliding window; it does not span nodes or survive a
      restart. Replay protection, not rate limiting, is what is durable here.

  Authentication and this ledger confer no authority. Standing: UNVERIFIED (written without an
  Elixir toolchain; no run cited).

  Options: `:store` (required, the `EKV` instance name), `:name`, `:now` (zero-arity ms clock).
  """

  use GenServer

  @key_prefix "email_ledger/key/"
  @result_prefix "email_ledger/result/"

  def start_link(opts) do
    unless Keyword.get(opts, :store), do: raise(ArgumentError, "#{inspect(__MODULE__)} requires :store")
    gen_opts = if opts[:name], do: [name: opts[:name]], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc false
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Same contract as `AshA2A.Email.TokenLedger.reserve/4`, plus `{:error, :ledger_unavailable}`."
  def reserve(ledger, brief_id, pairs, message_id),
    do: GenServer.call(ledger, {:reserve, brief_id, pairs, message_id})

  @doc "Same contract as `AshA2A.Email.TokenLedger.record_result/4`."
  def record_result(_ledger, _brief_id, nil, _body), do: :ok

  def record_result(ledger, brief_id, message_id, body),
    do: GenServer.call(ledger, {:record, brief_id, message_id, body})

  @doc "Node-local sliding-window rate check (see Limits)."
  def rate_check(ledger, sender, max, window_ms),
    do: GenServer.call(ledger, {:rate, sender, max, window_ms})

  # -- server ------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       store: Keyword.fetch!(opts, :store),
       hits: %{},
       now: Keyword.get(opts, :now, fn -> System.monotonic_time(:millisecond) end)
     }}
  end

  @impl GenServer
  def handle_call({:reserve, brief_id, pairs, mid}, _from, st) do
    {:reply, do_reserve(st.store, brief_id, pairs, mid), st}
  end

  def handle_call({:record, brief_id, mid, body}, _from, st) do
    case EKV.put(st.store, result_key(brief_id, mid), body) do
      {:ok, _} -> {:reply, :ok, st}
      :ok -> {:reply, :ok, st}
      _ -> {:reply, :ok, st}
    end
  end

  def handle_call({:rate, sender, max, window_ms}, _from, st) do
    now = st.now.()
    recent = st.hits |> Map.get(sender, []) |> Enum.filter(&(now - &1 < window_ms))

    if length(recent) >= max do
      {:reply, {:error, :rate_limited}, %{st | hits: Map.put(st.hits, sender, recent)}}
    else
      {:reply, :ok, %{st | hits: Map.put(st.hits, sender, [now | recent])}}
    end
  end

  # -- reserve -------------------------------------------------------------------

  defp do_reserve(store, brief_id, pairs, mid) do
    keys = pairs |> Enum.map(fn {n, token} -> key(brief_id, n, token) end) |> Enum.uniq()

    {inserted, outcome} =
      Enum.reduce_while(keys, {[], :ok}, fn k, {ins, :ok} ->
        case EKV.put(store, k, %{mid: mid}, if_vsn: nil) do
          {:ok, _vsn} ->
            {:cont, {[k | ins], :ok}}

          {:error, :conflict} ->
            {:halt, {ins, :conflict}}

          _other ->
            {:halt, {ins, :unavailable}}
        end
      end)

    cond do
      outcome == :ok ->
        :ok

      outcome == :unavailable ->
        rollback(store, inserted)
        {:error, :ledger_unavailable}

      inserted == [] and replay?(store, keys, mid) ->
        {:replay, cached(store, brief_id, mid)}

      true ->
        rollback(store, inserted)
        {:error, :already_consumed}
    end
  end

  defp replay?(_store, _keys, mid) when not is_binary(mid), do: false

  defp replay?(store, keys, mid) do
    Enum.all?(keys, fn k ->
      case EKV.get(store, k) do
        %{mid: ^mid} -> true
        _ -> false
      end
    end)
  end

  defp cached(store, brief_id, mid) do
    case EKV.get(store, result_key(brief_id, mid)) do
      nil -> nil
      body -> body
    end
  end

  defp rollback(store, keys), do: Enum.each(keys, &EKV.delete(store, &1))

  defp key(brief_id, n, token) do
    @key_prefix <> digest({brief_id, n, token})
  end

  defp result_key(brief_id, mid), do: @result_prefix <> digest({brief_id, mid})

  defp digest(term),
    do: :sha256 |> :crypto.hash(:erlang.term_to_binary(term)) |> Base.url_encode64(padding: false)
end
