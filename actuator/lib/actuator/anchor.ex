defmodule Actuator.Anchor do
  @moduledoc """
  The head anchor: `<state_dir>/anchor.json` records the (sequence, chain-head hash) of the
  journal and of the effect ledger, in a file SEPARATE from both and replaced atomically
  (write temp, fsync, rename, fsync directory). It is written after every fsync'd journal
  append, so it can lag the files by at most the record in flight during a crash, never lead
  them. At boot `check/3` requires each file to still contain the anchored head at the
  anchored position: a file that is shorter, or whose record at that position differs, is a
  truncation or rewrite and the Store refuses to start (fail closed).

  A missing anchor beside non-empty state is a refusal, not a fresh directory.
  """
  alias Actuator.Ledger

  @fields ~w(journal_seq journal_head ledger_seq ledger_head)

  def path(dir), do: Path.join(dir, "anchor.json")

  @doc "Atomically replace the anchor."
  def write(dir, %{journal_seq: js, journal_head: jh, ledger_seq: ls, ledger_head: lh}) do
    final = path(dir)
    tmp = final <> ".tmp"

    body =
      Jason.encode!(%{
        "v" => 1,
        "journal_seq" => js,
        "journal_head" => jh,
        "ledger_seq" => ls,
        "ledger_head" => lh
      })

    with {:ok, fd} <- :file.open(tmp, [:write, :binary, :raw]),
         :ok <- :file.write(fd, body),
         :ok <- :file.sync(fd),
         :ok <- :file.close(fd),
         :ok <- File.rename(tmp, final) do
      sync_dir(dir)
      :ok
    end
  end

  @doc "`:missing | {:ok, anchor} | {:error, :anchor_corrupt}`."
  def read(dir) do
    case File.read(path(dir)) do
      {:error, :enoent} ->
        :missing

      {:ok, raw} ->
        with {:ok, %{"v" => 1} = m} <- Jason.decode(raw),
             true <- Enum.all?(@fields, &Map.has_key?(m, &1)),
             true <- is_integer(m["journal_seq"]) and m["journal_seq"] >= 0,
             true <- is_integer(m["ledger_seq"]) and m["ledger_seq"] >= 0,
             true <- is_binary(m["journal_head"]) and is_binary(m["ledger_head"]) do
          {:ok,
           %{
             journal_seq: m["journal_seq"],
             journal_head: m["journal_head"],
             ledger_seq: m["ledger_seq"],
             ledger_head: m["ledger_head"]
           }}
        else
          _ -> {:error, :anchor_corrupt}
        end

      {:error, _} ->
        {:error, :anchor_corrupt}
    end
  end

  @doc """
  Check the verified journal hashes and ledger hashes (in file order) against the anchor.
  Returns `:ok` or `{:error, {code, detail}}`.
  """
  def check(dir, journal_hashes, ledger_hashes) do
    case read(dir) do
      :missing ->
        if journal_hashes == [] and ledger_hashes == [],
          do: :ok,
          else:
            {:error,
             {:anchor_missing, %{journal: length(journal_hashes), ledger: length(ledger_hashes)}}}

      {:error, code} ->
        {:error, {code, nil}}

      {:ok, a} ->
        with :ok <- prefix(:journal_truncated, a.journal_seq, a.journal_head, journal_hashes) do
          prefix(:ledger_truncated, a.ledger_seq, a.ledger_head, ledger_hashes)
        end
    end
  end

  defp prefix(code, 0, head, _hashes),
    do: if(head == Ledger.zero(), do: :ok, else: {:error, {code, %{anchored: 0}}})

  defp prefix(code, n, head, hashes) do
    if length(hashes) >= n and Enum.at(hashes, n - 1) == head,
      do: :ok,
      else: {:error, {code, %{anchored: n, found: length(hashes)}}}
  end

  defp sync_dir(dir) do
    with {:ok, fd} <- :file.open(dir, [:read, :raw]) do
      _ = :file.sync(fd)
      :file.close(fd)
    end

    :ok
  rescue
    _ -> :ok
  end
end
