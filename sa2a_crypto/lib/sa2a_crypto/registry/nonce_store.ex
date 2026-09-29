defmodule Sa2aCrypto.NonceStore do
  @moduledoc """
  Durable replay store keyed on `(kid, nonce)` (never on signature bytes).

  `check_and_set/4` is an atomic test-and-insert serialized through one process: the
  record is appended to the log and `fsync`ed BEFORE `:ok` is returned, so an acknowledged
  nonce survives a process restart (`start_link/2` replays the log). A torn final line
  (crash mid-append, never acknowledged) is ignored; corruption elsewhere refuses to
  start (`{:error, :nonce_log_corrupt}`), failing closed.

  `prune/2` removes an entry only when `now > expires + skew` (skew default 30s), then
  compacts the log by atomic rewrite. Until then a replay stays refused.

  Limit: one owning process per log path per node; no cross-node coordination.
  """
  use GenServer

  @default_skew 30

  @spec start_link(Path.t(), keyword()) :: GenServer.on_start()
  def start_link(path, opts \\ []) do
    {gen_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, {path, opts}, gen_opts)
  end

  @doc "Atomic check-and-set. `expires` is the message expiry (unix seconds)."
  @spec check_and_set(GenServer.server(), String.t(), String.t(), integer()) ::
          :ok | {:error, :replayed | :bad_nonce | :not_durable}
  def check_and_set(server, kid, nonce, expires)
      when is_binary(kid) and is_binary(nonce) and is_integer(expires),
      do: GenServer.call(server, {:cas, kid, nonce, expires})

  def check_and_set(_, _, _, _), do: {:error, :bad_nonce}

  @spec seen?(GenServer.server(), String.t(), String.t()) :: boolean()
  def seen?(server, kid, nonce), do: GenServer.call(server, {:seen, kid, nonce})

  @doc "Prunes entries with `now > expires + skew`; returns the number removed."
  @spec prune(GenServer.server(), integer()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def prune(server, now) when is_integer(now), do: GenServer.call(server, {:prune, now})

  @spec size(GenServer.server()) :: non_neg_integer()
  def size(server), do: GenServer.call(server, :size)

  @impl true
  def init({path, opts}) do
    skew = Keyword.get(opts, :skew, @default_skew)

    with {:ok, entries, torn?} <- load(path),
         :ok <- if(torn?, do: rewrite(path, entries), else: :ok),
         {:ok, io} <- open(path) do
      {:ok, %{path: path, io: io, entries: entries, skew: skew}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:seen, kid, nonce}, _from, s),
    do: {:reply, Map.has_key?(s.entries, {kid, nonce}), s}

  def handle_call(:size, _from, s), do: {:reply, map_size(s.entries), s}

  def handle_call({:cas, kid, nonce, expires}, _from, s) do
    key = {kid, nonce}

    if Map.has_key?(s.entries, key) do
      {:reply, {:error, :replayed}, s}
    else
      line = Jason.encode!([kid, nonce, expires]) <> "\n"

      with :ok <- :file.write(s.io, line),
           :ok <- :file.sync(s.io) do
        {:reply, :ok, %{s | entries: Map.put(s.entries, key, expires)}}
      else
        _ -> {:reply, {:error, :not_durable}, s}
      end
    end
  end

  def handle_call({:prune, now}, _from, s) do
    {keep, drop} = Enum.split_with(s.entries, fn {_, exp} -> not (now > exp + s.skew) end)

    if drop == [] do
      {:reply, {:ok, 0}, s}
    else
      kept = Map.new(keep)

      with :ok <- :file.close(s.io),
           :ok <- rewrite(s.path, kept),
           {:ok, io} <- open(s.path) do
        {:reply, {:ok, length(drop)}, %{s | io: io, entries: kept}}
      else
        {:error, reason} -> {:stop, {:prune_failed, reason}, {:error, reason}, s}
      end
    end
  end

  @impl true
  def terminate(_, %{io: io}), do: :file.close(io)

  defp open(path), do: :file.open(String.to_charlist(path), [:append, :binary, :raw])

  defp load(path) do
    case File.read(path) do
      {:error, :enoent} -> {:ok, %{}, false}
      {:error, _} -> {:error, :nonce_log_unreadable}
      {:ok, bin} -> parse(bin)
    end
  end

  defp parse(bin) do
    lines = String.split(bin, "\n")
    # The last element is "" when the file ends with a newline; otherwise it is a torn,
    # never-acknowledged tail, which is dropped (and the log rewritten without it).
    {body, [tail]} = Enum.split(lines, -1)

    body
    |> Enum.reduce_while({:ok, %{}}, fn line, {:ok, acc} ->
      case Jason.decode(line) do
        {:ok, [kid, nonce, exp]} when is_binary(kid) and is_binary(nonce) and is_integer(exp) ->
          {:cont, {:ok, Map.put(acc, {kid, nonce}, exp)}}

        _ ->
          {:halt, {:error, :nonce_log_corrupt}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, entries, tail != ""}
      err -> err
    end
  end

  defp rewrite(path, entries) do
    tmp = "#{path}.tmp-#{System.unique_integer([:positive])}"

    data =
      entries
      |> Enum.sort()
      |> Enum.map(fn {{k, n}, e} -> Jason.encode!([k, n, e]) <> "\n" end)

    with {:ok, io} <- :file.open(String.to_charlist(tmp), [:write, :binary, :raw]),
         :ok <- :file.write(io, data),
         :ok <- :file.sync(io),
         :ok <- :file.close(io),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, _} = e ->
        File.rm(tmp)
        e
    end
  end
end
