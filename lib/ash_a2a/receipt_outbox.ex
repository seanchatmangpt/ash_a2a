defmodule AshA2A.ReceiptOutbox do
  @moduledoc """
  Filesystem-backed receipt journal for CommandBus receipt closure.

  Consequence-bearing commands persist a `:pending` receipt here before
  dispatch. The finalized receipt later replaces that same file. If primary
  receipt commit and final outbox replacement both fail after dispatch, the
  pending receipt remains, so replay can be blocked without inventing an
  outcome.

  Storage defaults to `System.tmp_dir!()/ash_a2a_receipt_outbox`. Hosts can
  configure `:receipt_outbox_dir` to a stronger host volume -- and must, for
  a durable receipt store: `AshA2A.ReceiptStore.boot_check/1` refuses a
  durable store paired with a tmp outbox (finding R2), because the anchor is
  the at-most-once proof and must outlive a reboot exactly as long as the
  claim store does. This module provides host-local restart evidence; it
  does not claim transactional atomicity with an arbitrary external system.

  ## Durability of a write

  `append/1` writes a temp file with `:sync`, renames it over the entry, then
  fsyncs the directory (finding R2), so the rename itself survives a crash on
  platforms whose `file:open/2` supports `:directory`.

  ## Command-keyed file names (finding R5)

  Entries are named `<command-key>--<receipt id>.receipt`, where
  `<command-key>` is a truncated SHA-256 of the external command id.
  `anchored_command?/1` is therefore one directory listing and a prefix match
  -- no decoding -- and a torn file blocks reclaim only for its own command.
  Legacy entries (`<receipt id>.receipt`, written before this format) are
  still read, decoded when consulted, and migrated by `migrate_legacy/0`
  (called from `AshA2A.ReceiptOutbox.Reconciler.init/1`); an unreadable
  legacy entry blocks every reclaim (fail closed).

  ## Decoding is `:safe`

  Journal bytes are decoded with `:erlang.binary_to_term(bytes, [:safe])`
  (finding TQ-04): a hostile or corrupted file can never mint atoms or
  funs; it decodes to `{:error, :bad_term}` and is reported by
  `corrupt_entries/0`.
  """

  alias AshA2A.{Command, Identity, Receipt}

  require Logger

  @format_version 1
  @suffix ".receipt"
  @keyed_magic "SA2AJ1K"
  @marker_magic "SA2AJ1U"
  @mac_size 32
  @warn_key {__MODULE__, :unkeyed_warned}

  @doc """
  The configured journal integrity key (RFC-SA2A-004 section 12): the
  `:receipt_outbox_key`, else `:receipt_binding_key`, when a non-empty
  binary; otherwise `nil`.
  """
  @spec integrity_key() :: binary() | nil
  def integrity_key do
    Enum.find_value([:receipt_outbox_key, :receipt_binding_key], fn name ->
      case Application.get_env(:ash_a2a, name) do
        key when is_binary(key) and byte_size(key) > 0 -> key
        _ -> nil
      end
    end)
  end

  # Keyed: magic <> HMAC-SHA256(key, term bytes) <> term bytes. Unkeyed:
  # marker magic <> term bytes, so a later keyed runtime can tell the entry
  # was never tagged and refuse it (a planted forgery is indistinguishable
  # from it, by design).
  defp seal(term_bytes) do
    case integrity_key() do
      nil ->
        warn_unkeyed_once()
        @marker_magic <> term_bytes

      key ->
        @keyed_magic <> :crypto.mac(:hmac, :sha256, key, term_bytes) <> term_bytes
    end
  end

  defp warn_unkeyed_once do
    if :persistent_term.get(@warn_key, false) == false do
      :persistent_term.put(@warn_key, true)

      Logger.warning(
        "AshA2A.ReceiptOutbox: no :receipt_outbox_key/:receipt_binding_key configured; " <>
          "journal entries are written UNTAGGED and a keyed runtime will refuse them"
      )
    end

    :ok
  end

  defp unseal(binary) do
    key = integrity_key()

    case binary do
      <<@keyed_magic, mac::binary-size(@mac_size), rest::binary>> ->
        cond do
          key == nil -> {:error, :outbox_key_unavailable}
          :crypto.hash_equals(mac, :crypto.mac(:hmac, :sha256, key, rest)) -> {:ok, rest}
          true -> {:error, :outbox_bad_tag}
        end

      <<@marker_magic, rest::binary>> ->
        if key == nil, do: {:ok, rest}, else: {:error, :outbox_untagged_entry}

      other ->
        # Legacy / foreign bytes carry no tag.
        if key == nil, do: {:ok, other}, else: {:error, :outbox_untagged_entry}
    end
  end

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
    payload = seal(:erlang.term_to_binary({@format_version, receipt}))

    with :ok <- File.mkdir_p(dir()),
         :ok <- File.write(tmp_path, payload, [:binary, :sync]),
         :ok <- File.rename(tmp_path, entry_path) do
      sync_dir(dir())
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

  # fsync the directory so the rename is crash-durable. Best effort: a
  # platform without directory fds keeps the pre-R2 behavior.
  defp sync_dir(dir) do
    case :file.open(String.to_charlist(dir), [:read, :raw, :directory]) do
      {:ok, fd} ->
        _ = :file.sync(fd)
        _ = :file.close(fd)
        :ok

      {:error, _reason} ->
        :ok
    end
  rescue
    _error -> :ok
  end

  @doc "Whether this receipt identity already has a journal entry."
  @spec anchored?(Receipt.t()) :: boolean()
  def anchored?(%Receipt{} = receipt),
    do: File.regular?(entry_path(receipt)) or File.regular?(legacy_path(receipt))

  @doc """
  Whether ANY journal entry (pending or finalized, readable or torn, or an
  in-progress temp write) exists for `command_id` -- the anchor test
  `AshA2A.ReceiptStore.ClaimLease` uses before reclaiming a claim.

  Command-keyed entries are matched by file-name prefix without decoding. A
  legacy-named entry is decoded; an unreadable legacy entry, or an unlistable
  directory, answers `true` (fail closed).
  """
  @spec anchored_command?(Identity.t()) :: boolean()
  def anchored_command?(%Identity{} = command_id) do
    prefix = command_key(command_id) <> "--"

    case File.ls(dir()) do
      {:ok, names} ->
        Enum.any?(names, &String.starts_with?(&1, prefix)) or
          legacy_anchored?(names, command_id)

      {:error, :enoent} ->
        false

      {:error, _reason} ->
        true
    end
  end

  defp legacy_anchored?(names, command_id) do
    names
    |> Enum.filter(&legacy_entry?/1)
    |> Enum.any?(fn filename ->
      case decode_entry(filename) do
        {:ok, %Receipt{command_id: ^command_id}} -> true
        {:ok, %Receipt{}} -> false
        {:error, _reason} -> true
      end
    end)
  end

  @doc """
  Journal files that cannot be decoded (torn, foreign format, hostile
  bytes), as `[{filename, reason}]`, in stable filename order (finding
  OBS-09). They are counted in `reconcile/2`'s `:remaining` and never
  removed automatically: an unreadable file may be the very anchor proving
  DO started.
  """
  @spec corrupt_entries() :: [{String.t(), term()}]
  def corrupt_entries do
    Enum.flat_map(entry_names(), fn filename ->
      case decode_entry(filename) do
        {:ok, _receipt} -> []
        {:error, reason} -> [{filename, reason}]
      end
    end)
  end

  @doc """
  Rewrites every decodable legacy-named entry (`<receipt id>.receipt`) into
  the command-keyed format, then removes the legacy file. Unreadable legacy
  files are left in place (they keep blocking reclaim, fail closed). Returns
  the number migrated.
  """
  @spec migrate_legacy() :: non_neg_integer()
  def migrate_legacy do
    entry_names()
    |> Enum.filter(&legacy_entry?/1)
    |> Enum.reduce(0, fn filename, migrated ->
      with {:ok, %Receipt{command_id: %Identity{}} = receipt} <- decode_entry(filename),
           false <- File.regular?(entry_path(receipt)),
           :ok <- append(receipt),
           :ok <- File.rm(Path.join(dir(), filename)) do
        migrated + 1
      else
        true ->
          # A command-keyed entry already exists (a newer write); the
          # legacy copy is superseded.
          _ = File.rm(Path.join(dir(), filename))
          migrated

        _other ->
          migrated
      end
    end)
  end

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
      {:ok, stored} ->
        if supersedes?(receipt, stored),
          do: commit_or_reclaim(store, store_opts, receipt),
          else: remove_and(:already_present, receipt)

      _not_present ->
        commit_or_reclaim(store, store_opts, receipt)
    end
  end

  # A finalized entry supersedes its own pending anchor already drained into
  # the primary store (e.g. by a concurrent reconcile while the executor was
  # still inside DO): discarding it would erase the observed outcome and
  # leave the command permanently "prepared, outcome unknown"
  # (RFC-SA2A-002 §70; SA2A-CHAOS-012).
  defp supersedes?(%Receipt{receipt_id: id, status: status}, %Receipt{
         receipt_id: id,
         status: :pending
       })
       when status != :pending,
       do: true

  defp supersedes?(_entry, _stored), do: false

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

      {:error, :stale_execution} ->
        # The claim is held by a different execution (it was reclaimed after
        # this entry's execution lost it). This entry is evidence of a DO
        # the primary store does not know about; keep it for an operator /
        # `AshA2A.Reconciliation` rather than overwriting the live claim.
        Logger.warning(
          "AshA2A.ReceiptOutbox: entry #{Identity.external(receipt.receipt_id)} belongs to a " <>
            "superseded execution of #{Identity.external(receipt.command_id)}; kept"
        )

        :pending

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

    # The claim is re-created under the receipt's OWN execution id (a store
    # honoring `:execution_id` in its claim opts -- Memory and Ekv do), so the
    # fenced commit (finding R4) accepts it and the receipt's binding, which
    # covers `execution_id`, stays intact. A store that ignores the option
    # fences the commit out and the entry stays journaled -- never lost.
    claim_opts = Keyword.put(store_opts, :execution_id, receipt.execution_id)

    case safe(store, :claim, [command, claim_opts]) do
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
    _ = File.rm(legacy_path(receipt))

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
    _ = File.rm(legacy_path(receipt))

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

  @doc """
  The journal path for a receipt of `command_id` with `receipt_id` --
  exported so fixtures that capture the raw journal bytes at the prepare
  boundary do not reconstruct the naming scheme by hand.
  """
  @spec entry_path_for(Identity.t(), Identity.t()) :: String.t()
  def entry_path_for(%Identity{} = command_id, %Identity{} = receipt_id) do
    Path.join(dir(), command_key(command_id) <> "--" <> Identity.external(receipt_id) <> @suffix)
  end

  defp entry_path(%Receipt{command_id: %Identity{} = command_id, receipt_id: receipt_id}),
    do: entry_path_for(command_id, receipt_id)

  defp entry_path(%Receipt{} = receipt), do: legacy_path(receipt)

  defp legacy_path(%Receipt{} = receipt) do
    Path.join(dir(), Identity.external(receipt.receipt_id) <> @suffix)
  end

  defp command_key(%Identity{} = command_id) do
    :crypto.hash(:sha256, Identity.external(command_id))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  defp legacy_entry?(filename) do
    String.ends_with?(filename, @suffix) and not Regex.match?(~r/\A[0-9a-f]{32}--/, filename)
  end

  defp decode_entry(filename) do
    path = Path.join(dir(), filename)

    with {:ok, raw} <- File.read(path),
         {:ok, binary} <- unseal(raw),
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

  # `:safe` refuses atoms not already in the atom table. A journal written by
  # another VM names struct modules (`AshA2A.Evidence.*`, `AshA2A.Identity`,
  # ...) that a freshly restarted VM has not lazily loaded yet, so without
  # this a legitimate crash-window anchor decodes as `:bad_term`. Loading the
  # application's own compiled modules registers exactly those atoms and no
  # attacker-controlled ones.
  @modules_loaded_key {__MODULE__, :modules_loaded}
  defp ensure_app_modules_loaded do
    if :persistent_term.get(@modules_loaded_key, false) == false do
      (Application.spec(:ash_a2a, :modules) || []) |> Enum.each(&Code.ensure_loaded/1)
      :persistent_term.put(@modules_loaded_key, true)
    end

    :ok
  end

  defp safe_binary_to_term(binary) do
    ensure_app_modules_loaded()

    case :erlang.binary_to_term(binary, [:safe]) do
      {@format_version, %Receipt{} = receipt} -> {:ok, receipt}
      {@format_version, _other} -> :foreign_format
      {_other_version, _} -> :foreign_format
      _ -> :foreign_format
    end
  rescue
    _ -> {:error, :bad_term}
  end
end
