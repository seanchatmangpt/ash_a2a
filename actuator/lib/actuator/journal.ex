defmodule Actuator.Journal do
  @moduledoc """
  The write-ahead journal as a hash chain: every line carries `seq`, `prev` and
  `hash = sha256(prev <> JCS(body-without-hash))` (same construction as `Actuator.Ledger`,
  `prev(0)` = 64 zeros). A removed, reordered or edited record breaks the chain; a truncated
  tail is caught by `Actuator.Anchor`. `cross_check/2` ties the journal to the effect ledger.
  """
  alias Actuator.Ledger

  @doc "Encode one event as `{line_with_newline, hash}` at position `seq` after `prev`."
  def encode(event, seq, prev) do
    body = Map.merge(event, %{"seq" => seq, "prev" => prev})
    hash = Ledger.hash(prev, body)
    {Jcs.encode(Map.put(body, "hash", hash)) <> "\n", hash}
  end

  @doc "Build chained lines for a list of bare events: `{lines_without_newline, count, head}`."
  def build(events) do
    {lines, {n, head}} =
      Enum.map_reduce(events, {0, Ledger.zero()}, fn ev, {i, prev} ->
        {line, h} = encode(ev, i, prev)
        {String.trim_trailing(line, "\n"), {i + 1, h}}
      end)

    {lines, n, head}
  end

  @doc """
  Read and verify the whole chain. `{:ok, %{events: [...], hashes: [...], count: n, head: h}}`
  or `{:error, {:journal_broken_chain, index, why}}`.
  """
  def verify(path) do
    events =
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    Enum.reduce_while(
      events,
      {:ok, %{events: [], hashes: [], count: 0, head: Ledger.zero()}},
      fn e, {:ok, acc} ->
        {h, body} = Map.pop(e, "hash")

        cond do
          e["seq"] != acc.count ->
            {:halt, {:error, {:journal_broken_chain, acc.count, :seq}}}

          e["prev"] != acc.head ->
            {:halt, {:error, {:journal_broken_chain, acc.count, :prev}}}

          Ledger.hash(acc.head, body) != h ->
            {:halt, {:error, {:journal_broken_chain, acc.count, :hash}}}

          true ->
            {:cont,
             {:ok,
              %{
                events: [e | acc.events],
                hashes: [h | acc.hashes],
                count: acc.count + 1,
                head: h
              }}}
        end
      end
    )
    |> case do
      {:ok, acc} ->
        {:ok, %{acc | events: Enum.reverse(acc.events), hashes: Enum.reverse(acc.hashes)}}

      err ->
        err
    end
  rescue
    _ -> {:error, {:journal_broken_chain, 0, :unparseable}}
  end

  @doc """
  Journal vs ledger. Every ledger entry must belong to a journaled claim; every event must
  follow its claim; every `completed` event naming a ledger seq must match that entry's
  instance and hash. A claim with no terminal record is NOT an error here: the Store turns
  it into `unknown_outcome` (never re-performed).
  """
  def cross_check(events, entries) do
    by_seq = entries |> Enum.with_index() |> Map.new(fn {e, i} -> {i, e} end)

    result =
      Enum.reduce_while(events, MapSet.new(), fn ev, claims ->
        id = ev["instance_id"]

        case ev["t"] do
          "executing" ->
            {:cont, MapSet.put(claims, id)}

          t ->
            cond do
              not MapSet.member?(claims, id) ->
                {:halt, {:error, {:journal_orphan_event, id}}}

              t == "completed" and is_integer(ev["ledger_seq"]) and
                  not match_entry?(by_seq[ev["ledger_seq"]], id, ev["ledger_hash"]) ->
                {:halt, {:error, {:journal_ledger_mismatch, id}}}

              true ->
                {:cont, claims}
            end
        end
      end)

    case result do
      {:error, _} = e ->
        e

      claims ->
        case Enum.find(entries, &(not MapSet.member?(claims, &1["effect_instance_id"]))) do
          nil -> :ok
          e -> {:error, {:ledger_without_claim, e["effect_instance_id"]}}
        end
    end
  end

  defp match_entry?(nil, _, _), do: false

  defp match_entry?(entry, id, hash),
    do: entry["effect_instance_id"] == id and entry["hash"] == hash
end
