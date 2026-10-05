# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.EffectClaimStore.DurableFile do
  @moduledoc """
  Durable, file-backed `AshA2A.C2.ClaimStore`: compare-and-set claims that
  survive a BEAM restart (the state is the filesystem, not a process).

  Configure with `config :ash_a2a, claim_store: #{inspect(__MODULE__)}` and
  `config :ash_a2a, claim_store_dir: "/durable/path/claims"`. A directory
  under a volatile tmp root is refused (`:claim_store_dir_not_durable`) using
  `AshA2A.ReceiptStore.durable_path?/1`.

  ## Guarantees

    * `claim/2`: compare-and-set. A second claim of the same digest returns
      `{:error, :already_claimed}`.
    * Fence atomic with the write: under one directory lock the store compares
      `generation` with the highest generation ever claimed (kept in the
      authenticated head, file `fence`). Lower is `{:error, :stale_generation}`
      and writes nothing. The head is written first (with a pending intent),
      then the record, then the head again without the intent, so a crash can
      only over-fence, never under-fence.
    * `complete/2` records the result once (`{:error, {:already_complete, r}}`
      thereafter) and refuses an unclaimed digest (`{:error, :not_claimed}`).
    * Every record and the head carry an HMAC-SHA256 under a mandatory key
      (`:claim_store_key`, else `:receipt_outbox_key`, else
      `:receipt_binding_key`; >= 32 bytes; absent is `:claim_key_missing`,
      short is `:claim_key_unavailable`). The record MAC binds the record's
      file name, so a record cannot be forged, edited or moved to another
      digest: `{:error, :claim_record_corrupt}`, never trusted.
    * Loss and rollback are detected. The head holds `acc`, the XOR of every
      record's MAC. Each operation audits the directory; a deleted, added or
      rolled-back record (or a deleted head while records exist) is
      `{:error, :claim_log_corrupt}`, so record loss cannot re-open a claim.
      Limit: restoring a whole older directory (head and records together)
      is not detectable without an external anchor.

  Cross-process exclusion is a `mkdir` lock (atomic on POSIX) with a stale-lock
  timeout, so it serialises separate OS processes as well as local tasks.
  The store has no process and no in-memory state.
  """

  @behaviour AshA2A.C2.ClaimStore

  alias AshA2A.ReceiptStore

  @lock_wait_ms 10_000
  @lock_stale_ms 30_000

  @doc false
  def __sa2a_refusal_codes__ do
    %{
      claim_store_dir_not_durable: :refused_receipt,
      claim_record_corrupt: :refused_receipt,
      claim_log_corrupt: :refused_receipt,
      claim_key_missing: :refused_receipt,
      claim_key_unavailable: :refused_receipt,
      claim_store_lock_timeout: :refused_receipt,
      stale_generation: :refused_authority,
      not_claimed: :refused_receipt
    }
  end

  @doc "Proves durability to the conformance verifier (`c1.durable_claim_store`)."
  @spec durable?() :: true
  def durable?, do: true

  @impl true
  def claim(digest, generation), do: claim(digest, generation, configured_dir())

  @impl true
  def complete(digest, result), do: complete(digest, result, configured_dir())

  @doc "Claims `digest` at `generation` in `dir`."
  @spec claim(binary(), non_neg_integer(), Path.t() | nil) :: :ok | {:error, term()}
  def claim(digest, generation, dir) when is_integer(generation) and generation >= 0 do
    with_store(dir, fn dir, key ->
      with {:ok, st} <- audit(dir, key),
           :ok <- check_fence(st, generation) do
        name = name(digest)

        case Map.fetch(st.recs, name) do
          :error ->
            commit(
              dir,
              key,
              st,
              name,
              %{state: :claimed, generation: generation, result: nil},
              generation
            )

          {:ok, _} ->
            {:error, :already_claimed}
        end
      end
    end)
  end

  @doc "Completes a claimed `digest` with `result` in `dir`."
  @spec complete(binary(), term(), Path.t() | nil) :: :ok | {:error, term()}
  def complete(digest, result, dir) do
    with_store(dir, fn dir, key ->
      with {:ok, st} <- audit(dir, key) do
        name = name(digest)

        case Map.fetch(st.recs, name) do
          :error ->
            {:error, :not_claimed}

          {:ok, {_tag, %{state: :complete, result: r}}} ->
            {:error, {:already_complete, r}}

          {:ok, {_tag, %{state: :claimed} = rec}} ->
            commit(dir, key, st, name, %{rec | state: :complete, result: result}, st.generation)
        end
      end
    end)
  end

  @doc "Reads the record for `digest`: `{:ok, %{state, generation, result}}`, `:not_found` or an error."
  @spec fetch(binary(), Path.t() | nil) :: {:ok, map()} | :not_found | {:error, term()}
  def fetch(digest, dir \\ nil) do
    with_store(dir || configured_dir(), fn dir, key ->
      with {:ok, st} <- audit(dir, key) do
        case Map.fetch(st.recs, name(digest)) do
          {:ok, {_tag, rec}} -> {:ok, rec}
          :error -> :not_found
        end
      end
    end)
  end

  # -- internals --

  @zero <<0::256>>
  @rec_ctx "SA2A-CLAIM-REC-v1\0"
  @head_ctx "SA2A-CLAIM-HEAD-v1\0"

  defp configured_dir, do: Application.get_env(:ash_a2a, :claim_store_dir)

  defp resolve_key do
    k =
      Application.get_env(:ash_a2a, :claim_store_key) ||
        Application.get_env(:ash_a2a, :receipt_outbox_key) ||
        Application.get_env(:ash_a2a, :receipt_binding_key)

    cond do
      is_nil(k) -> {:error, :claim_key_missing}
      is_binary(k) and byte_size(k) >= 32 -> {:ok, k}
      true -> {:error, :claim_key_unavailable}
    end
  end

  defp with_store(dir, fun) do
    if ReceiptStore.durable_path?(dir) do
      dir = Path.expand(dir)

      with {:ok, key} <- resolve_key(),
           :ok <- File.mkdir_p(Path.join(dir, "claims")),
           {:ok, lock} <- acquire(dir) do
        try do
          fun.(dir, key)
        after
          File.rmdir(lock)
        end
      end
    else
      {:error, :claim_store_dir_not_durable}
    end
  end

  defp acquire(dir), do: acquire(Path.join(dir, "lock"), System.monotonic_time(:millisecond))

  defp acquire(lock, started) do
    case File.mkdir(lock) do
      :ok ->
        {:ok, lock}

      {:error, reason} when reason == :eexist ->
        cond do
          stale?(lock) ->
            File.rmdir(lock)
            acquire(lock, started)

          System.monotonic_time(:millisecond) - started > @lock_wait_ms ->
            {:error, :claim_store_lock_timeout}

          true ->
            Process.sleep(2)
            acquire(lock, started)
        end

      {:error, reason} ->
        {:error, {:claim_store_lock, reason}}
    end
  end

  defp stale?(lock) do
    case File.stat(lock, time: :posix) do
      {:ok, %{mtime: m}} -> System.os_time(:second) - m > div(@lock_stale_ms, 1000)
      _ -> false
    end
  end

  defp name(digest), do: Base.encode16(:crypto.hash(:sha256, digest), case: :lower)
  defp claim_path(dir, name), do: Path.join([dir, "claims", name])
  defp fence_path(dir), do: Path.join(dir, "fence")

  defp mac(key, ctx, bin), do: :crypto.mac(:hmac, :sha256, key, [ctx, bin])
  defp rec_mac(key, name, body), do: mac(key, @rec_ctx, [name, 0, body])

  # Authenticated audit of head + every record. Fail closed on any mismatch.
  defp audit(dir, key) do
    with {:ok, recs} <- read_records(dir, key),
         {:ok, head} <- read_head(dir, key, map_size(recs)) do
      acc = Enum.reduce(recs, @zero, fn {_n, {tag, _}}, a -> :crypto.exor(a, tag) end)

      cond do
        acc == head.acc ->
          {:ok, %{generation: head.generation, acc: acc, recs: recs}}

        # crash between the pending head write and the record write: the
        # operation never happened; the fence stays raised (over-fence only)
        match?(%{old_tag: _, new_tag: _}, head.pending) and
            acc ==
              :crypto.exor(head.acc, :crypto.exor(head.pending.old_tag, head.pending.new_tag)) ->
          {:ok, %{generation: head.generation, acc: acc, recs: recs}}

        true ->
          {:error, :claim_log_corrupt}
      end
    end
  end

  defp read_records(dir, key) do
    case File.ls(Path.join(dir, "claims")) do
      {:ok, names} ->
        names
        |> Enum.reject(&String.contains?(&1, ".tmp."))
        |> Enum.reduce_while({:ok, %{}}, fn n, {:ok, acc} ->
          case read_authenticated(claim_path(dir, n), fn body -> rec_mac(key, n, body) end) do
            {:ok, tag, rec} -> {:cont, {:ok, Map.put(acc, n, {tag, rec})}}
            {:error, _} = e -> {:halt, e}
          end
        end)

      {:error, reason} ->
        {:error, {:claim_store_io, reason}}
    end
  end

  defp read_head(dir, key, nrecs) do
    case read_authenticated(fence_path(dir), fn body -> mac(key, @head_ctx, body) end) do
      {:ok, _tag, %{generation: g, acc: a} = h} ->
        {:ok, %{generation: g, acc: a, pending: h[:pending]}}

      {:ok, _, _} ->
        {:error, :claim_record_corrupt}

      {:error, :enoent} when nrecs == 0 ->
        {:ok, %{generation: nil, acc: @zero, pending: nil}}

      {:error, :enoent} ->
        {:error, :claim_log_corrupt}

      {:error, _} = e ->
        e
    end
  end

  defp check_fence(%{generation: nil}, _), do: :ok
  defp check_fence(%{generation: fence}, g) when g >= fence, do: :ok
  defp check_fence(_, _), do: {:error, :stale_generation}

  defp commit(dir, key, st, name, rec, generation) do
    body = encode(rec)
    new_tag = rec_mac(key, name, body)

    old_tag =
      case Map.get(st.recs, name),
        do: (
          nil -> @zero
          {t, _} -> t
        )

    acc = :crypto.exor(st.acc, :crypto.exor(old_tag, new_tag))
    gen = max(generation, st.generation || 0)

    with :ok <-
           write_head(dir, key, %{
             generation: gen,
             acc: acc,
             pending: %{old_tag: old_tag, new_tag: new_tag}
           }),
         :ok <- write_bytes(claim_path(dir, name), [new_tag, body]) do
      write_head(dir, key, %{generation: gen, acc: acc, pending: nil})
    end
  end

  defp write_head(dir, key, head) do
    body = encode(head)
    write_bytes(fence_path(dir), [mac(key, @head_ctx, body), body])
  end

  defp encode(term), do: :erlang.term_to_binary(term, [:deterministic])

  defp read_authenticated(path, mac_fun) do
    case File.read(path) do
      {:ok, <<sum::binary-size(32), body::binary>>} ->
        expected = mac_fun.(body)

        if :crypto.hash_equals(sum, expected) do
          try do
            {:ok, expected, :erlang.binary_to_term(body, [:safe])}
          rescue
            _ -> {:error, :claim_record_corrupt}
          end
        else
          {:error, :claim_record_corrupt}
        end

      {:ok, _} ->
        {:error, :claim_record_corrupt}

      {:error, :enoent} ->
        {:error, :enoent}

      {:error, reason} ->
        {:error, {:claim_store_io, reason}}
    end
  end

  defp write_bytes(path, iodata) do
    tmp = path <> ".tmp.#{System.unique_integer([:positive])}"

    with :ok <- File.write(tmp, iodata, [:binary, :sync]),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, {:claim_store_io, reason}}
    end
  end
end
