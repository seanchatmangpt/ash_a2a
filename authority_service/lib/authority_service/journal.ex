defmodule AuthorityService.Journal do
  @moduledoc """
  Append-only, hash-chained issuance journal (one JCS line per issuance, fsync before the
  certificate is signed or returned).

  Entry: `{"seq", "prev", "body", "hash"}` with `hash = sha256(prev <> JCS({seq, body}))`.
  A restart replays and verifies the chain; a broken chain or torn line refuses to open
  (`{:error, {:journal_corrupt, why}}`). Consequently a nonce that was ever reserved is
  never reissued, and consumed approvals `(kid, nonce)` and issued `(digest, generation)`
  pairs survive restart. If the process dies after fsync but before the response, the
  nonce is burned, never reused.
  """
  @genesis String.duplicate("0", 64)

  defstruct [
    :path,
    :io,
    seq: 0,
    head: @genesis,
    nonces: MapSet.new(),
    approvals: MapSet.new(),
    issued: MapSet.new()
  ]

  @type t :: %__MODULE__{}

  @spec open(Path.t()) :: {:ok, t()} | {:error, term()}
  def open(path) do
    File.mkdir_p!(Path.dirname(path))
    if not File.exists?(path), do: File.write!(path, "")
    File.chmod(path, 0o600)

    with {:ok, body} <- File.read(path),
         {:ok, j} <- replay(body, %__MODULE__{path: path}),
         {:ok, io} <- :file.open(path, [:append, :raw, :binary]) do
      {:ok, %{j | io: io}}
    else
      {:error, {:journal_corrupt, _}} = e -> e
      {:error, reason} -> {:error, {:journal_unopenable, reason}}
    end
  end

  def close(%__MODULE__{io: io}), do: :file.close(io)

  def nonce_seen?(%__MODULE__{nonces: n}, nonce), do: MapSet.member?(n, nonce)
  def approval_seen?(%__MODULE__{approvals: a}, kid, nonce), do: MapSet.member?(a, {kid, nonce})
  def issued?(%__MODULE__{issued: i}, digest, gen), do: MapSet.member?(i, {digest, gen})

  @doc "Durably append an issuance record. Returns only after fsync."
  @spec append(t(), map()) :: {:ok, t()} | {:error, term()}
  def append(%__MODULE__{} = j, body) when is_map(body) do
    seq = j.seq + 1
    hash = link(j.head, seq, body)
    line = Jcs.encode(%{"seq" => seq, "prev" => j.head, "body" => body, "hash" => hash}) <> "\n"

    with :ok <- :file.write(j.io, line),
         :ok <- :file.sync(j.io) do
      {:ok, apply_entry(%{j | seq: seq, head: hash}, body)}
    end
  end

  defp link(prev, seq, body),
    do:
      Base.encode16(:crypto.hash(:sha256, prev <> Jcs.encode(%{"seq" => seq, "body" => body})),
        case: :lower
      )

  defp apply_entry(j, body) do
    %{
      j
      | nonces: MapSet.put(j.nonces, body["nonce"]),
        approvals:
          Enum.reduce(body["approvals"] || [], j.approvals, fn [k, n], acc ->
            MapSet.put(acc, {k, n})
          end),
        issued: MapSet.put(j.issued, {body["effect_digest"], body["generation"]})
    }
  end

  defp replay("", j), do: {:ok, j}

  defp replay(text, j) do
    if String.ends_with?(text, "\n") do
      text
      |> String.split("\n", trim: true)
      |> Enum.reduce_while({:ok, j}, fn line, {:ok, acc} ->
        case entry(line, acc) do
          {:ok, acc} -> {:cont, {:ok, acc}}
          {:error, why} -> {:halt, {:error, {:journal_corrupt, why}}}
        end
      end)
    else
      {:error, {:journal_corrupt, :torn_line}}
    end
  end

  defp entry(line, j) do
    with {:ok, %{"seq" => seq, "prev" => prev, "body" => body, "hash" => hash}} <-
           Jason.decode(line),
         true <- seq == j.seq + 1 or {:error, :bad_seq},
         true <- prev == j.head or {:error, :bad_chain},
         true <- link(prev, seq, body) == hash or {:error, :bad_hash},
         true <- is_map(body) do
      {:ok, apply_entry(%{j | seq: seq, head: hash}, body)}
    else
      {:error, why} when is_atom(why) -> {:error, why}
      _ -> {:error, :malformed_line}
    end
  end
end
