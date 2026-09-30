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

  Head anchor (B2): after every append the `{seq, head}` pair is persisted separately
  (`anchor_path`, written atomically: tmp + fsync + rename). Open refuses (fail closed) a
  journal shorter than the anchored `seq` (`:journal_truncated`), whose entry at that `seq`
  does not carry the anchored head (`:anchor_mismatch`), or a non-empty journal with no
  anchor (`:anchor_missing`); an unreadable or malformed anchor is `:anchor_corrupt`. The
  journal may be at most ahead of the anchor (crash between the two writes), never behind.
  """
  @genesis String.duplicate("0", 64)

  defstruct [
    :path,
    :anchor_path,
    :io,
    heads: %{},
    seq: 0,
    head: @genesis,
    nonces: MapSet.new(),
    approvals: MapSet.new(),
    issued: MapSet.new()
  ]

  @type t :: %__MODULE__{}

  @spec open(Path.t(), Path.t() | nil) :: {:ok, t()} | {:error, term()}
  def open(path, anchor_path \\ nil) do
    anchor_path = anchor_path || path <> ".anchor"
    File.mkdir_p!(Path.dirname(path))
    if not File.exists?(path), do: File.write!(path, "")
    File.chmod(path, 0o600)

    with {:ok, body} <- File.read(path),
         {:ok, j} <- replay(body, %__MODULE__{path: path, anchor_path: anchor_path}),
         :ok <- check_anchor(j),
         {:ok, io} <- :file.open(path, [:append, :raw, :binary]),
         j <- %{j | io: io, heads: %{}},
         :ok <- write_anchor(j) do
      {:ok, j}
    else
      {:error, {:journal_corrupt, _}} = e -> e
      {:error, {:journal_anchor, _}} = e -> e
      {:error, reason} -> {:error, {:journal_unopenable, reason}}
    end
  end

  # ---- head anchor -------------------------------------------------------

  defp check_anchor(%__MODULE__{anchor_path: ap, seq: seq, heads: heads}) do
    case File.read(ap) do
      {:error, :enoent} ->
        if seq == 0, do: :ok, else: {:error, {:journal_anchor, :anchor_missing}}

      {:error, _} ->
        {:error, {:journal_anchor, :anchor_corrupt}}

      {:ok, bin} ->
        with {:ok, %{"seq" => aseq, "head" => ahead} = a}
             when is_integer(aseq) and aseq >= 0 and is_binary(ahead) and map_size(a) == 2 <-
               Sa2aCrypto.StrictJson.decode(bin) do
          cond do
            seq < aseq -> {:error, {:journal_anchor, :journal_truncated}}
            aseq == 0 and ahead == @genesis -> :ok
            Map.get(heads, aseq) == ahead -> :ok
            true -> {:error, {:journal_anchor, :anchor_mismatch}}
          end
        else
          _ -> {:error, {:journal_anchor, :anchor_corrupt}}
        end
    end
  end

  defp write_anchor(%__MODULE__{anchor_path: ap, seq: seq, head: head}) do
    tmp = ap <> ".tmp"
    bin = Jcs.encode(%{"seq" => seq, "head" => head})

    with {:ok, io} <- :file.open(tmp, [:write, :raw, :binary]),
         :ok <- :file.write(io, bin),
         :ok <- :file.sync(io),
         :ok <- :file.close(io),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, ap) do
      :ok
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

    j2 = %{j | seq: seq, head: hash}

    with :ok <- :file.write(j.io, line),
         :ok <- :file.sync(j.io),
         :ok <- write_anchor(j2) do
      {:ok, apply_entry(j2, body)}
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
           Sa2aCrypto.StrictJson.decode(line, canonical: false),
         true <- seq == j.seq + 1 or {:error, :bad_seq},
         true <- prev == j.head or {:error, :bad_chain},
         true <- link(prev, seq, body) == hash or {:error, :bad_hash},
         true <- is_map(body) do
      {:ok, apply_entry(%{j | seq: seq, head: hash, heads: Map.put(j.heads, seq, hash)}, body)}
    else
      {:error, why} when is_atom(why) -> {:error, why}
      _ -> {:error, :malformed_line}
    end
  end
end
