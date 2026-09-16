defmodule AshA2A.ReceiptOutbox do
  @moduledoc """
  Filesystem-backed receipt journal for CommandBus receipt closure.

  Consequence-bearing commands persist a `:pending` receipt here before
  dispatch. The finalized receipt later replaces that same file. If primary
  receipt commit and final outbox replacement both fail after dispatch, the
  pending receipt remains, so replay can be blocked without inventing an
  outcome.

  Storage defaults to `System.tmp_dir!()/ash_a2a_receipt_outbox`. Hosts can
  configure `:receipt_outbox_dir` to a stronger host volume. This module
  provides host-local restart evidence; it does not claim transactional
  atomicity with an arbitrary external system.
  """

  alias AshA2A.{Command, Identity, Receipt}

  require Logger

  @format_version 1
  @suffix ".receipt"

  @doc "The journal directory."
  @spec dir() :: String.t()
  def dir do
    Application.get_env(:ash_a2a, :receipt_outbox_dir) ||
      Path.join(System.tmp_dir!(), "ash_a2a_receipt_outbox")
  end

  @doc "Appends or replaces one receipt journal entry."
  @spec append(Receipt.t()) :: :ok | {:error, term()}
  def append(%Receipt{} = receipt) do
    entry_path = entry_path(receipt)
    tmp_path = entry_path <> ".tmp.#{System.unique_integer([:positive])}"
    payload = :erlang.term_to_binary({@format_version, receipt})

    with :ok <- File.mkdir_p(dir()),
         :ok <- File.write(tmp_path, payload, [:binary, :sync]),
         :ok <- File.rename(tmp_path, entry_path) do
      :ok
    else
      {:error, _reason} = error ->
        File.rm(tmp_path)
        error
    end
  rescue
    error -> {:error, {:outbox_exception, error}}
  catch
    kind, reason -> {:error, {:outbox_throw, kind, reason}}
  end

  @doc "Whether this receipt identity already has a journal entry."
  @spec anchored?(Receipt.t()) :: boolean()
  def anchored?(%Receipt{} = receipt), do: File.regular?(entry_path(receipt))

  @doc "Number of receipt files currently awaiting reconciliation."
  @spec count() :: non_neg_integer()
  def count, do: length(entry_names())

  @doc "All readable journaled receipts in stable filename order."
  @spec entries() :: [Receipt.t()]
  def entries do
    entry_names()
    |> Enum.flat_map(fn filename ->
      case decode_entry(filename) do
        {:ok, receipt} -> [receipt]
        {:error, _reason} -> []
      end
    end)
  end

  @doc """
  Drains journal entries into `store`.

  A `:pending` receipt is committed as pending. It proves the command crossed
  the pre-dispatch receipt boundary but does not infer a final consequence
  outcome. That receipt therefore blocks replay from executing a second DO.
  """
  @spec reconcile(module(), keyword()) ::
          {:ok, %{committed: non_neg_integer(), remaining: non_neg_integer()}}
  def reconcile(store \\ AshA2A.CommandBus.default_store(), store_opts \\ []) do
    {committed, remaining} =
      Enum.reduce(entry_names(), {0, 0}, fn filename, {ok, keep} ->
        case decode_entry(filename) do
          {:ok, receipt} ->
            case reconcile_entry(store, store_opts, receipt) do
              :committed -> {ok + 1, keep}
              :already_present -> {ok, keep}
              :pending -> {ok, keep + 1}
            end

          {:error, _reason} ->
            {ok, keep + 1}
        end
      end)

    {:ok, %{committed: committed, remaining: remaining}}
  end

  defp mark_reconciled(%Receipt{status: :pending} = receipt), do: receipt

  defp mark_reconciled(%Receipt{} = receipt),
    do: Receipt.reconcile(receipt, %{source: :receipt_outbox})

  defp reconcile_entry(store, store_opts, %Receipt{} = receipt) do
    case safe(store, :fetch, [receipt.command_id, store_opts]) do
      {:ok, _stored} ->
        remove_and(:already_present, receipt)

      _not_present ->
        commit_or_reclaim(store, store_opts, receipt)
    end
  end

  defp commit_or_reclaim(store, store_opts, receipt) do
    # RFC-SA2A-001 S31: a receipt that only reaches the primary store via this
    # drain is `:reconciled`, not plainly `:executed` -- the distinction is the
    # whole point of having a separate terminal status for it. A still-pending
    # anchor is left alone: `Receipt.reconcile/2` would claim an outcome that
    # was never observed.
    receipt = mark_reconciled(receipt)

    case safe(store, :commit, [receipt, store_opts]) do
      :ok ->
        remove_and(:committed, receipt)

      {:error, :unclaimed_command} ->
        re_claim_and_commit(store, store_opts, receipt)

      {:error, _unavailable} ->
        :pending
    end
  end

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
        remove_and(:already_present, receipt)

      {:execute, _execution_id} ->
        case safe(store, :commit, [receipt, store_opts]) do
          :ok -> remove_and(:committed, receipt)
          {:error, _unavailable} -> :pending
        end

      {:error, _unavailable} ->
        :pending
    end
  end

  defp remove_and(result, receipt) do
    case File.rm(entry_path(receipt)) do
      :ok ->
        result

      {:error, :enoent} ->
        result

      {:error, reason} ->
        Logger.warning(
          "AshA2A.ReceiptOutbox: could not remove reconciled entry: #{inspect(reason)}"
        )

        :pending
    end
  end

  @doc "Removes `receipt`'s journal entry (idempotent; missing is :ok)."
  @spec remove(Receipt.t()) :: :ok
  def remove(%Receipt{} = receipt) do
    case File.rm(entry_path(receipt)) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("AshA2A.ReceiptOutbox: could not remove journal entry: #{inspect(reason)}")

        :ok
    end
  end

  defp safe(store, function, args) do
    apply(store, function, args)
  rescue
    _error -> {:error, :receipt_store_unavailable}
  catch
    :exit, _reason -> {:error, :receipt_store_unavailable}
  end

  defp entry_names do
    case File.ls(dir()) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, @suffix))
        |> Enum.sort()

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.warning(
          "AshA2A.ReceiptOutbox: cannot list journal directory #{dir()}: #{inspect(reason)}"
        )

        []
    end
  end

  defp entry_path(%Receipt{} = receipt) do
    Path.join(dir(), Identity.external(receipt.receipt_id) <> @suffix)
  end

  defp decode_entry(filename) do
    path = Path.join(dir(), filename)

    with {:ok, binary} <- File.read(path),
         {:ok, %Receipt{} = receipt} <- safe_binary_to_term(binary) do
      {:ok, receipt}
    else
      {:error, reason} = error ->
        Logger.warning("AshA2A.ReceiptOutbox: unreadable entry #{path}: #{inspect(reason)}")

        error

      :foreign_format ->
        Logger.warning("AshA2A.ReceiptOutbox: entry #{path} has foreign format")
        {:error, :foreign_format}
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
