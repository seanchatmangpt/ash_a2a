defmodule AshA2A.Semantic.Episode.Envelope do
  @moduledoc """
  A handle to one admitted resource envelope (RFC-SA2A-002 §83, §127, §132).

  The handle carries identity only. Ceilings and consumption live in
  `AshA2A.Semantic.Episode.Ledger`, the single source of truth, so an edited
  or stale copy of a handle (for example one captured before an episode
  consumed the envelope) can never be spent as if it were fresh: every spend,
  delegation and reissue reads the ledger, never the handle.

  `authority` is structurally `:none`: an envelope is budget, never
  permission (`Budget ⇏ Authority`).
  """

  @enforce_keys [:id, :issued_by]
  defstruct [:id, :issued_by, :parent_id, authority: :none]

  @type t :: %__MODULE__{
          id: String.t(),
          issued_by: term(),
          parent_id: String.t() | nil,
          authority: :none
        }
end

defmodule AshA2A.Semantic.Episode.Ledger do
  @moduledoc """
  Serialized, authoritative accounting for `AshA2A.Semantic.Episode`
  envelopes.

  Every mutation is one `transact/2` call executed inside this process, so a
  check-and-debit (spend, delegation, reissue) is atomic across concurrent
  episodes sharing an envelope: two episodes cannot both spend the last unit.

  The process is started on first use (unlinked, registered) rather than by
  the application supervisor. If it is unavailable, or a transaction raises,
  the caller receives a typed `:episode_ledger_unavailable` refusal -- an
  unreadable ledger is never read as headroom. A restarted ledger knows no
  envelope, so every previously issued handle fails closed as
  `:episode_envelope_unknown`.
  """

  use GenServer

  @call_timeout 30_000

  @doc false
  def __sa2a_refusal_codes__, do: %{episode_ledger_unavailable: :blocked_resource}

  @doc "Starts the registered ledger if it is not running."
  @spec ensure_started() :: {:ok, pid()} | {:error, map()}
  def ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        case GenServer.start(__MODULE__, :ok, name: __MODULE__) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> unavailable(reason)
        end

      pid ->
        {:ok, pid}
    end
  end

  @doc "The ledger entry for `id`."
  @spec fetch(String.t()) :: {:ok, map()} | {:error, map()}
  def fetch(id), do: call({:fetch, id})

  @doc "Registers a new entry. Refuses a duplicate id."
  @spec register(map()) :: :ok | {:error, map()}
  def register(%{id: id} = entry) when is_binary(id), do: call({:register, entry})

  @doc """
  Runs `fun.(%{id => entry})` atomically for the existing entries `ids`.

  `fun` returns `{:ok, %{id => entry}, reply}` (entries to write, new or
  updated) or `{:error, refusal}` (nothing is written). Returns
  `{:ok, reply}` or the refusal.
  """
  @spec transact([String.t()], (map() -> {:ok, map(), term()} | {:error, map()})) ::
          {:ok, term()} | {:error, map()}
  def transact(ids, fun) when is_list(ids) and is_function(fun, 1),
    do: call({:transact, ids, fun})

  defp call(message) do
    with {:ok, pid} <- ensure_started() do
      GenServer.call(pid, message, @call_timeout)
    end
  catch
    :exit, reason -> unavailable(reason)
  end

  defp unavailable(reason),
    do:
      {:error,
       %{code: :episode_ledger_unavailable, detail: inspect(reason, limit: 10), resource: nil}}

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:fetch, id}, _from, entries) do
    case Map.fetch(entries, id) do
      {:ok, entry} -> {:reply, {:ok, entry}, entries}
      :error -> {:reply, unknown(id), entries}
    end
  end

  def handle_call({:register, %{id: id} = entry}, _from, entries) do
    if Map.has_key?(entries, id),
      do:
        {:reply, {:error, %{code: :episode_envelope_unknown, detail: {:duplicate, id}}}, entries},
      else: {:reply, :ok, Map.put(entries, id, entry)}
  end

  def handle_call({:transact, ids, fun}, _from, entries) do
    case Enum.reject(ids, &Map.has_key?(entries, &1)) do
      [] ->
        try do
          case fun.(Map.take(entries, ids)) do
            {:ok, writes, reply} when is_map(writes) ->
              {:reply, {:ok, reply}, Map.merge(entries, writes)}

            {:error, %{code: _} = refusal} ->
              {:reply, {:error, refusal}, entries}

            other ->
              {:reply, unavailable({:malformed_transaction, other}), entries}
          end
        rescue
          exception -> {:reply, unavailable(Exception.message(exception)), entries}
        end

      [missing | _] ->
        {:reply, unknown(missing), entries}
    end
  end

  defp unknown(id),
    do:
      {:error,
       %{
         code: :episode_envelope_unknown,
         detail: "no envelope #{inspect(id)} was issued by this runtime's ledger",
         resource: nil
       }}
end
