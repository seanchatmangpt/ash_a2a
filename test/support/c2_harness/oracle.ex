# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule C2Harness.Oracle do
  @moduledoc """
  The court oracle: the Actuator's append-only hash-chained effect ledger and the
  issuance journals, read from disk BY THE HARNESS (never by the control plane) and
  verified with an implementation that shares no code with `Actuator.Ledger` or
  `AuthorityService.Journal` (the chain is re-derived here from `:crypto` and `Jcs`).

  ## Pass rule (RFC-SA2A-006 s26, as tightened by this court)

  For one attack, with `before`/`after` the ledger snapshots around it and `authorized` the
  effect digests the issuance journal legitimately authorizes and that remain valid:

    1. the `after` chain verifies and `before` is a prefix of it (nothing rewritten);
    2. every NEW ledger entry's `effect_digest` is in `authorized` AND occurs in the
       issuance journal;
    3. for every digest that gained an entry, ledger entries <= issuance-journal entries for
       that digest (one issuance buys at most one consequence: a duplicated DO fails here even
       though the digest is authorized).

  Zero new entries always passes 1-3. A refusal code, exception, crash or timeout is never
  evidence on its own; only these three conditions are.
  """
  @zero String.duplicate("0", 64)

  # ---- files ----------------------------------------------------------------

  @doc "Ledger entries and chain status for an actuator state dir."
  @spec ledger(Path.t()) :: {:ok, [map()]} | {:error, term(), [map()]}
  def ledger(state_dir) do
    entries = state_dir |> Path.join("effect_ledger.jsonl") |> read_lines()

    case verify_ledger(entries) do
      :ok -> {:ok, entries}
      {:error, why} -> {:error, why, entries}
    end
  end

  @doc "Entries of the actuator's own claim journal (`executing`/`completed`/...)."
  def claims(state_dir), do: state_dir |> Path.join("journal.jsonl") |> read_lines()

  @doc "Bodies of a hash-chained issuance journal (Keymaster or AuthorityService format)."
  @spec journal(Path.t()) :: {:ok, [map()]} | {:error, term(), [map()]}
  def journal(path) do
    lines = read_lines(path)

    case verify_journal(lines) do
      :ok -> {:ok, Enum.map(lines, & &1["body"])}
      {:error, why} -> {:error, why, Enum.map(lines, &(&1["body"] || %{}))}
    end
  end

  # complete lines only: a final line without "\n" is a write in flight (or torn)
  defp read_lines(path) do
    case File.read(path) do
      {:ok, data} ->
        parts = String.split(data, "\n")
        complete = if String.ends_with?(data, "\n"), do: parts, else: Enum.drop(parts, -1)

        complete
        |> Enum.reject(&(&1 == ""))
        |> Enum.flat_map(fn l ->
          case Jason.decode(l) do
            {:ok, m} when is_map(m) -> [m]
            _ -> [%{"__unparseable__" => true}]
          end
        end)

      {:error, _} ->
        []
    end
  end

  # ---- chains (independent derivations) ---------------------------------------

  def verify_ledger(entries) do
    Enum.reduce_while(Enum.with_index(entries), @zero, fn {e, i}, head ->
      {h, body} = Map.pop(e, "hash")

      cond do
        e["seq"] != i -> {:halt, {:broken_chain, i, :seq}}
        e["prev"] != head -> {:halt, {:broken_chain, i, :prev}}
        is_nil(h) or sha(head <> Jcs.encode(body)) != h -> {:halt, {:broken_chain, i, :hash}}
        true -> {:cont, h}
      end
    end)
    |> case do
      {:broken_chain, _, _} = e -> {:error, e}
      _head -> :ok
    end
  rescue
    _ -> {:error, {:broken_chain, 0, :unparseable}}
  end

  def verify_journal(lines) do
    Enum.reduce_while(Enum.with_index(lines, 1), @zero, fn {e, i}, head ->
      cond do
        e["seq"] != i ->
          {:halt, {:broken_chain, i, :seq}}

        e["prev"] != head ->
          {:halt, {:broken_chain, i, :prev}}

        sha(head <> Jcs.encode(%{"seq" => i, "body" => e["body"]})) != e["hash"] ->
          {:halt, {:broken_chain, i, :hash}}

        true ->
          {:cont, e["hash"]}
      end
    end)
    |> case do
      {:broken_chain, _, _} = e -> {:error, e}
      _head -> :ok
    end
  rescue
    _ -> {:error, {:broken_chain, 0, :unparseable}}
  end

  defp sha(bin), do: Base.encode16(:crypto.hash(:sha256, bin), case: :lower)

  # ---- verdicts -------------------------------------------------------------------

  @doc """
  Apply the pass rule. `issuance` are Keymaster journal bodies. Returns
  `{:pass, diff}` or `{:fail, reasons, diff}`; `diff` lists the new ledger entries.
  """
  @spec verdict([map()], [map()], [String.t()], [map()]) ::
          {:pass, [map()]} | {:fail, [term()], [map()]}
  def verdict(before, aft, authorized, issuance) do
    diff = Enum.drop(aft, length(before))

    reasons =
      Enum.reject(
        [
          chain_reason(aft),
          prefix_reason(before, aft)
        ] ++
          new_entry_reasons(diff, authorized, issuance) ++ duplicate_reasons(aft, diff, issuance),
        &is_nil/1
      )

    if reasons == [], do: {:pass, diff}, else: {:fail, reasons, diff}
  end

  defp chain_reason(aft) do
    case verify_ledger(aft) do
      :ok -> nil
      {:error, why} -> {:ledger_chain_broken, why}
    end
  end

  defp prefix_reason(before, aft) do
    if Enum.take(aft, length(before)) == before, do: nil, else: :ledger_rewritten
  end

  defp new_entry_reasons(diff, authorized, issuance) do
    for e <- diff do
      d = e["effect_digest"]

      cond do
        d not in authorized ->
          {:unauthorized_entry, e["seq"], d, :not_authorized_for_attack}

        issued_count(issuance, d) == 0 ->
          {:unauthorized_entry, e["seq"], d, :not_in_issuance_journal}

        true ->
          nil
      end
    end
  end

  # Only digests that gained an entry during THIS attack: an earlier attack's violation is
  # that attack's verdict and must not contaminate every later attack in the same fleet.
  defp duplicate_reasons(aft, diff, issuance) do
    touched = diff |> Enum.map(& &1["effect_digest"]) |> Enum.uniq()

    aft
    |> Enum.frequencies_by(& &1["effect_digest"])
    |> Enum.flat_map(fn {d, n} ->
      if d in touched and n > issued_count(issuance, d),
        do: [{:duplicate_do, d, n, issued_count(issuance, d)}],
        else: []
    end)
  end

  @doc "Number of journal issuances for an effect digest."
  def issued_count(issuance, digest), do: Enum.count(issuance, &(&1["effect_digest"] == digest))

  @doc """
  Authority-side rule: NEW real-authority journal entries must be `{digest, generation}` pairs
  in `authorized`, and no pair may appear twice in the whole journal.
  """
  @spec authority_verdict([map()], [map()], [{String.t(), integer()}]) ::
          {:pass, [map()]} | {:fail, [term()], [map()]}
  def authority_verdict(before, aft, authorized) do
    diff = Enum.drop(aft, length(before))
    key = &{&1["effect_digest"], &1["generation"]}

    reasons =
      for(e <- diff, key.(e) not in authorized, do: {:unauthorized_issuance, key.(e)}) ++
        (aft
         |> Enum.frequencies_by(key)
         |> Enum.flat_map(fn {k, n} -> if n > 1, do: [{:duplicate_issuance, k, n}], else: [] end))

    if reasons == [], do: {:pass, diff}, else: {:fail, reasons, diff}
  end
end
