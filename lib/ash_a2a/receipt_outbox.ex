defmodule AshA2A.ReceiptOutbox do
  @moduledoc """
  Durable append-only fallback journal for receipts whose primary
  `AshA2A.ReceiptStore` commit failed AFTER a consequence was observed
  (A2A-2601).

  `AshA2A.CommandBus.run/4`'s sequence is claim -> dispatch -> commit. When
  the real dispatch succeeds (the consequence has happened) and the store's
  `commit/2` then fails, previously the outcome reply was discarded and the
  claim left dangling with no durable receipt anywhere. This journal closes
  that gap: the receipt is appended here first (one file per receipt,
  external term format, atomic tmp+rename write), and only then is the
  typed `{:error, %{code: :receipt_commit_pending, receipt: receipt}}`
  outcome returned to the caller -- so a consequence is never left
  unreceipted, even while its primary store is down.

  ## Durability class

  Storage defaults to `System.tmp_dir!()/ash_a2a_receipt_outbox` -- the
  same durability class as `AshA2A.ReceiptStore.Ekv`'s own default data
  dir (survives a BEAM restart; an OS tmp cleaner may reclaim it). Hosts
  that need real disk set `config :ash_a2a, :receipt_outbox_dir, "..."`.

  ## Reconciliation

  `reconcile/3` drains journal entries back into the store once it has
  recovered: each entry is committed (re-claiming the command id first
  when the store lost the claim, e.g. a restarted
  `AshA2A.ReceiptStore.Memory`), then removed from the journal on
  success. `AshA2A.CommandBus.run/4` opportunistically reconciles a
  non-empty journal before claiming, so the next command through the bus
  repairs the previous one's pending receipt without operator action.

  Journal files use `:erlang.term_to_binary/1` (total over arbitrary
  `reply` terms Jason cannot encode). They are machine-local, operator-
  owned files; do not point `:receipt_outbox_dir` at untrusted storage --
  `binary_to_term/1` on attacker-chosen bytes is not safe. The decoded
  payload is a version-tagged tuple so a future format can refuse old (or
  foreign) entries explicitly instead of misreading them.
  """

  alias AshA2A.{Command, Identity, Receipt}

  require Logger

  @format_version 1
  @suffix ".receipt"

  @doc "The journal directory (see moduledoc's Durability class section)."
  @spec dir() :: String.t()
  def dir do
    Application.get_env(:ash_a2a, :receipt_outbox_dir) ||
      Path.join(System.tmp_dir!(), "ash_a2a_receipt_outbox")
  end

  @doc """
  Durably appends `receipt` to the journal: writes a tmp file in the same
  directory then renames it over the entry path, so a reader never observes
  a torn entry. Returns `{:error, reason}` (never raises) so the caller can
  distinguish "outboxed" from "outbox itself failed".
  """
  @spec append(Receipt.t()) :: :ok | {:error, term()}
  def append(%Receipt{} = receipt) do
    entry_path = entry_path(receipt)
    tmp_path = entry_path <> ".tmp.#{System.unique_integer([:positive])}"
    payload = :erlang.term_to_binary({@format_version, receipt})

    with :ok <- File.mkdir_p(dir()),
         :ok <- File.write(tmp_path, payload),
         :ok <- File.rename(tmp_path, entry_path) do
      :ok
    else
      {:error, _reason} = error ->
        File.rm(tmp_path)
        error
    end
  end

  @doc "Number of receipts currently awaiting reconciliation."
  @spec count() :: non_neg_integer()
  def count, do: length(entries())

  @doc """
  All journaled receipts, in stable entry-filename order (UUIDv7 receipt
  ids are time-ordered, so filename order approximates append order). A
  corrupt or foreign-format entry is skipped with a warning rather than
  crashing the caller -- and, because entries are written tmp-then-rename,
  a torn entry cannot exist; the skip is for genuinely foreign bytes.
  """
  @spec entries() :: [Receipt.t()]
  def entries do
    case File.ls(dir()) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, @suffix))
        |> Enum.sort()
        |> Enum.flat_map(&decode_entry/1)

      {:error, :enoent} ->
        []
    end
  end

  @doc """
  Drains the journal into `store` (default: `CommandBus.default_store/0`).
  For each entry: if the store already holds the receipt, drop the entry;
  otherwise commit it, re-claiming the command id first when the store
  lost the claim (a restarted `AshA2A.ReceiptStore.Memory` has no memory
  of the original claim). Entries whose store is still unavailable stay
  journaled for the next attempt. Never raises: store crashes count as
  "still unavailable". Returns committed/remaining counts.
  """
  @spec reconcile(module(), keyword()) ::
          {:ok, %{committed: non_neg_integer(), remaining: non_neg_integer()}}
  def reconcile(store \\ AshA2A.CommandBus.default_store(), store_opts \\ []) do
    {committed, remaining} =
      Enum.reduce(entries(), {0, 0}, fn receipt, {ok, keep} ->
        case reconcile_entry(store, store_opts, receipt) do
          :committed -> {ok + 1, keep}
          :already_present -> {ok, keep}
          :pending -> {ok, keep + 1}
        end
      end)

    {:ok, %{committed: committed, remaining: remaining}}
  end

  defp reconcile_entry(store, store_opts, %Receipt{} = receipt) do
    case safe(store, :fetch, [receipt.command_id, store_opts]) do
      {:ok, _stored} ->
        :already_present |> tap(fn _ -> remove(receipt) end)

      :error ->
        commit_or_reclaim(store, store_opts, receipt)
    end
  end

  defp commit_or_reclaim(store, store_opts, receipt) do
    case safe(store, :commit, [receipt, store_opts]) do
      :ok ->
        :committed |> tap(fn _ -> remove(receipt) end)

      {:error, :unclaimed_command} ->
        re_claim_and_commit(store, store_opts, receipt)

      {:error, _unavailable} ->
        :pending
    end
  end

  # The store restarted and lost the original claim (an in-process Map does
  # not survive): re-establish the claim with a minimal command carrying
  # the SAME command id and fingerprint the original claim was keyed on
  # (both bundled stores' claim logic reads exactly those two fields), then
  # commit the journaled receipt against it.
  defp re_claim_and_commit(store, store_opts, receipt) do
    command = %Command{
      command_id: receipt.command_id,
      agent_id: receipt.agent_id,
      principal_id: receipt.principal_id,
      capability_id: receipt.capability_id,
      input: %{},
      submitted_at: DateTime.utc_now(),
      fingerprint: receipt.fingerprint
    }

    case safe(store, :claim, [command, store_opts]) do
      {:replay, _receipt} ->
        :already_present |> tap(fn _ -> remove(receipt) end)

      {:execute, _execution_id} ->
        case safe(store, :commit, [receipt, store_opts]) do
          :ok ->
            :committed |> tap(fn _ -> remove(receipt) end)

          {:error, _unavailable} ->
            :pending
        end

      {:error, _unavailable} ->
        :pending
    end
  end

  @doc "Removes `receipt`'s journal entry (idempotent; missing is :ok)."
  @spec remove(Receipt.t()) :: :ok
  def remove(%Receipt{} = receipt) do
    File.rm(entry_path(receipt))
    :ok
  end

  # Calls `store.function(args)` under run/4's existing fail-closed no-raise
  # contract: a crash (`:noproc` exit, ArgumentError) is normalized into
  # `{:error, :receipt_store_unavailable}` rather than propagated, and a
  # plain `{:error, reason}` reply is passed through unchanged.
  defp safe(store, function, args) do
    apply(store, function, args)
  rescue
    _error -> {:error, :receipt_store_unavailable}
  catch
    :exit, _reason -> {:error, :receipt_store_unavailable}
  end

  defp entry_path(%Receipt{} = receipt) do
    Path.join(dir(), Identity.external(receipt.receipt_id) <> @suffix)
  end

  defp decode_entry(filename) do
    path = Path.join(dir(), filename)

    with {:ok, binary} <- File.read(path),
         {:ok, %Receipt{} = receipt} <- safe_binary_to_term(binary) do
      [receipt]
    else
      {:error, reason} ->
        Logger.warning(
          "AshA2A.ReceiptOutbox: skipping unreadable entry #{path}: #{inspect(reason)}"
        )

        []

      :foreign_format ->
        Logger.warning("AshA2A.ReceiptOutbox: skipping entry #{path} with foreign format")
        []
    end
  end

  defp safe_binary_to_term(binary) do
    case :erlang.binary_to_term(binary) do
      {@format_version, %Receipt{} = receipt} -> {:ok, receipt}
      {@format_version, _other} -> :foreign_format
      {_other_version, _} -> :foreign_format
      _ -> :foreign_format
    end
  rescue
    _ -> {:error, :bad_term}
  end
end
