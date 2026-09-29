defmodule Actuator.Ledger do
  @moduledoc """
  The actuator's own effect ledger: an append-only, hash-chained, fsync'd file
  (`<state_dir>/effect_ledger.jsonl`), one JCS JSON object per line:

      {seq, prev, effect_instance_id, effect_digest, entry, hash}
      hash = hex(sha256(prev <> JCS(body-without-hash)))     prev(0) = 64 zeros

  `read/1` and `verify/1` are the public oracle surface: anything can re-derive the chain
  from the file alone. The Store verifies the chain at boot and refuses to start on a break.
  """
  @zero String.duplicate("0", 64)

  defstruct [:path, :fd, seq: 0, head: @zero]

  def path(dir), do: Path.join(dir, "effect_ledger.jsonl")
  def zero, do: @zero

  @doc "Open (creating), truncate a torn tail, verify the chain, position at the head."
  def open(dir) do
    path = path(dir)
    File.touch!(path)
    trim_torn_tail(path)

    case verify(path) do
      {:ok, %{count: n, head: head}} ->
        {:ok, fd} = :file.open(path, [:append, :binary, :raw])
        {:ok, %__MODULE__{path: path, fd: fd, seq: n, head: head}}

      {:error, _} = e ->
        e
    end
  end

  def close(%__MODULE__{fd: fd}), do: :file.close(fd)

  @spec append(t(), map()) ::
          {:ok, %{ledger: t(), seq: integer(), hash: String.t()}} | {:error, term()}
  def append(%__MODULE__{} = l, body) when is_map(body) do
    body = Map.merge(body, %{"seq" => l.seq, "prev" => l.head})
    hash = hash(l.head, body)
    line = Jcs.encode(Map.put(body, "hash", hash)) <> "\n"

    with :ok <- :file.write(l.fd, line), :ok <- :file.sync(l.fd) do
      {:ok, %{ledger: %{l | seq: l.seq + 1, head: hash}, seq: l.seq, hash: hash}}
    end
  end

  @type t :: %__MODULE__{}

  def hash(prev, body_without_hash),
    do: Base.encode16(:crypto.hash(:sha256, prev <> Jcs.encode(body_without_hash)), case: :lower)

  @doc "All entries (decoded maps) in file order."
  def read(path_or_dir) do
    path = if File.dir?(path_or_dir), do: path(path_or_dir), else: path_or_dir

    case File.read(path) do
      {:ok, data} -> data |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      {:error, :enoent} -> []
    end
  end

  @doc "Re-derive the whole chain from the file."
  def verify(path_or_dir) do
    path = if File.dir?(path_or_dir), do: path(path_or_dir), else: path_or_dir

    Enum.reduce_while(read(path), {:ok, %{count: 0, head: @zero}}, fn e, {:ok, acc} ->
      {h, body} = Map.pop(e, "hash")

      cond do
        e["seq"] != acc.count -> {:halt, {:error, {:broken_chain, acc.count, :seq}}}
        e["prev"] != acc.head -> {:halt, {:error, {:broken_chain, acc.count, :prev}}}
        hash(acc.head, body) != h -> {:halt, {:error, {:broken_chain, acc.count, :hash}}}
        true -> {:cont, {:ok, %{count: acc.count + 1, head: h}}}
      end
    end)
  rescue
    _ -> {:error, {:broken_chain, 0, :unparseable}}
  end

  @doc false
  def trim_torn_tail(path) do
    data = File.read!(path)

    unless data == "" or String.ends_with?(data, "\n") do
      keep =
        data
        |> :binary.matches("\n")
        |> List.last()
        |> then(&if(&1, do: elem(&1, 0) + 1, else: 0))

      {:ok, fd} = :file.open(path, [:read, :write, :binary, :raw])
      {:ok, _} = :file.position(fd, keep)
      :ok = :file.truncate(fd)
      :ok = :file.sync(fd)
      :file.close(fd)
    end

    :ok
  end
end
