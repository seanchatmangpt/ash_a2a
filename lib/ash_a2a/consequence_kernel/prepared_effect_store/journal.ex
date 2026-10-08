# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.PreparedEffectStore.Journal do
  @moduledoc """
  Durable, keyed, sequence-numbered `AshA2A.ConsequenceKernel.PreparedEffectStore`.

  State is an append-only log (`journal.log`) replayed on every operation, so a
  BEAM restart loses nothing. Use it as `{#{inspect(__MODULE__)}, handle}` where
  `handle` comes from `open/2` or `from_config/0`.

  ## Integrity

    * Entry `n` is `{n, prev_tag, event}`; its tag is the HMAC (via the
      configured `AshA2A.ConsequenceKernel.KeyCustody` provider) of those
      bytes, and entry `n+1` embeds entry `n`'s tag. Sequence numbers must be
      exactly `1..n`; an edit, swap, duplicate or gap is refused
      (`:prepared_authentication_failed`, `:journal_corrupt`,
      `:journal_sequence_gap`).
    * A MAC'd `head` file records the last sequence and tag; a log shorter than
      the head is `:journal_truncated`.
    * The key is mandatory: `open/2` without a provider is
      `:journal_key_missing`; a provider whose key is unusable (HMAC needs
      >= 32 bytes) is `:prepared_key_unavailable`. A tmp or unset directory is
      `:journal_dir_not_durable`.

  Writers are serialised across OS processes by a `mkdir` lock. Appends are
  `fsync`ed before the head is advanced.
  """

  @behaviour AshA2A.ConsequenceKernel.PreparedEffectStore

  alias AshA2A.ConsequenceKernel.KeyCustody
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Transition
  alias AshA2A.ReceiptStore

  @lock_wait_ms 10_000
  @lock_stale_s 30

  @type handle :: %{dir: Path.t(), key_provider: {module(), keyword()}}

  @doc false
  def __sa2a_refusal_codes__ do
    %{
      journal_key_missing: :refused_receipt,
      journal_dir_not_durable: :refused_receipt,
      journal_truncated: :refused_receipt,
      journal_corrupt: :refused_receipt,
      journal_sequence_gap: :refused_receipt,
      journal_lock_timeout: :refused_receipt
    }
  end

  @doc "Proves durability to callers that check it."
  def durable?, do: true

  @doc "Opens the journal in `dir` with `key_provider` (`{module, opts}`), refusing weak config."
  @spec open(Path.t() | nil, {module(), keyword()} | nil) :: {:ok, handle()} | {:error, atom()}
  def open(dir, key_provider) do
    cond do
      not ReceiptStore.durable_path?(dir) ->
        {:error, :journal_dir_not_durable}

      is_nil(key_provider) ->
        {:error, :journal_key_missing}

      true ->
        {provider, opts} = key_provider

        case KeyCustody.mac(provider, "sa2a-journal-open-probe", opts) do
          {:ok, _} -> {:ok, %{dir: Path.expand(dir), key_provider: key_provider}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Handle from application env: dir `:prepared_journal_dir` (default
  `<receipt_outbox_dir>/prepared_journal`), key `:receipt_outbox_key` or
  `:receipt_binding_key` under `KeyCustody.HmacSha256`.
  """
  @spec from_config() :: {:ok, handle()} | {:error, atom()}
  def from_config do
    dir =
      Application.get_env(:ash_a2a, :prepared_journal_dir) ||
        case Application.get_env(:ash_a2a, :receipt_outbox_dir) do
          d when is_binary(d) and d != "" -> Path.join(d, "prepared_journal")
          _ -> nil
        end

    key =
      Application.get_env(:ash_a2a, :receipt_outbox_key) ||
        Application.get_env(:ash_a2a, :receipt_binding_key)

    provider = if is_binary(key), do: {KeyCustody.HmacSha256, [key: key]}, else: nil
    open(dir, provider)
  end

  @doc "Sequence numbers present in the verified log."
  def sequence(h), do: with({:ok, st} <- load(h), do: {:ok, Enum.to_list(1..st.seq//1)})

  @doc "Verified head sequence number."
  def head(h), do: with({:ok, st} <- load(h), do: {:ok, st.seq})

  # -- PreparedEffectStore callbacks --

  @impl true
  def put(h, %{digest: digest} = record) do
    mutate(h, fn st ->
      if Map.has_key?(st.records, digest),
        do: {:error, :prepared_duplicate},
        else: {:ok, :ok, [{:put, Map.put(record, :outcome, nil)}]}
    end)
  end

  @impl true
  def fetch(h, digest) do
    with {:ok, st} <- load(h) do
      case Map.fetch(st.records, digest) do
        {:ok, r} -> {:ok, r}
        :error -> :not_found
      end
    end
  end

  @impl true
  def transition(h, digest, from, to) do
    mutate(h, fn st ->
      with {:ok, r} <- Map.fetch(st.records, digest),
           true <- r.state == from,
           :ok <- Transition.admit(from, to) do
        {:ok, :ok, [{:transition, digest, from, to}]}
      else
        _ -> {:error, :prepared_transition_refused}
      end
    end)
  end

  @impl true
  def claim_request(h, id, owner), do: claim(h, :requests, id, owner)
  @impl true
  def claim_effect(h, id, owner), do: claim(h, :effects, id, owner)

  @impl true
  def complete(h, digest, outcome) do
    mutate(h, fn st ->
      case Map.fetch(st.records, digest) do
        {:ok, %{state: :completed}} -> {:ok, :ok, [{:complete, digest, outcome}]}
        {:ok, _} -> {:error, :prepared_not_completed}
        :error -> {:error, :prepared_record_missing}
      end
    end)
  end

  defp claim(h, key, id, owner) do
    mutate(h, fn st ->
      case get_in(st, [key, id]) do
        nil -> {:ok, :ok, [{:claim, key, id, owner}]}
        ^owner -> {:ok, :ok, []}
        _ -> {:error, :claim_conflict}
      end
    end)
  end

  # -- log machinery --

  defp log_path(h), do: Path.join(h.dir, "journal.log")
  defp head_path(h), do: Path.join(h.dir, "head")

  defp empty, do: %{seq: 0, tag: "", records: %{}, requests: %{}, effects: %{}}

  defp apply_event(st, {:put, %{digest: d} = r}), do: put_in(st, [:records, d], r)
  defp apply_event(st, {:transition, d, _from, to}), do: put_in(st, [:records, d, :state], to)
  defp apply_event(st, {:complete, d, out}), do: put_in(st, [:records, d, :outcome], out)
  defp apply_event(st, {:claim, key, id, owner}), do: put_in(st, [key, id], owner)

  defp mutate(h, fun) do
    with_lock(h, fn ->
      with {:ok, st} <- load(h) do
        case fun.(st) do
          {:ok, reply, events} ->
            case append(h, st, events) do
              :ok -> reply
              {:error, _} = e -> e
            end

          {:error, _} = e ->
            e
        end
      end
    end)
  end

  defp append(_h, _st, []), do: :ok

  defp append(h, st, events) do
    {frames, last} =
      Enum.map_reduce(events, {st.seq, st.tag}, fn ev, {seq, prev} ->
        body = :erlang.term_to_binary({seq + 1, prev, ev}, [:deterministic])
        {:ok, tag} = mac(h, body)
        frame = <<byte_size(body)::32, body::binary, byte_size(tag)::16, tag::binary>>
        {frame, {seq + 1, tag}}
      end)

    {seq, tag} = last

    with {:ok, io} <- File.open(log_path(h), [:append, :binary, :raw]),
         :ok <- :file.write(io, frames),
         :ok <- :file.sync(io),
         :ok <- File.close(io) do
      write_head(h, seq, tag)
    else
      {:error, reason} -> {:error, {:journal_io, reason}}
    end
  end

  defp write_head(h, seq, tag) do
    body = :erlang.term_to_binary({seq, tag}, [:deterministic])
    {:ok, htag} = mac(h, body)
    tmp = head_path(h) <> ".tmp.#{System.unique_integer([:positive])}"

    with :ok <- File.write(tmp, [<<byte_size(body)::32>>, body, htag], [:binary, :sync]),
         :ok <- File.rename(tmp, head_path(h)) do
      :ok
    else
      {:error, reason} -> {:error, {:journal_io, reason}}
    end
  end

  defp load(h) do
    with :ok <- ensure_dir(h),
         {:ok, log} <- read_log(h),
         {:ok, st} <- replay(h, log, empty()) do
      check_head(h, st)
    end
  end

  defp ensure_dir(h) do
    case File.mkdir_p(h.dir) do
      :ok -> :ok
      {:error, r} -> {:error, {:journal_io, r}}
    end
  end

  defp read_log(h) do
    case File.read(log_path(h)) do
      {:ok, bin} -> {:ok, bin}
      {:error, :enoent} -> {:ok, <<>>}
      {:error, r} -> {:error, {:journal_io, r}}
    end
  end

  defp replay(_h, <<>>, st), do: {:ok, st}

  defp replay(
         h,
         <<blen::32, body::binary-size(blen), tlen::16, tag::binary-size(tlen), rest::binary>>,
         st
       ) do
    with :ok <- verify(h, body, tag),
         {:ok, {seq, prev, ev}} <- decode(body),
         :ok <- check_seq(seq, prev, st) do
      replay(h, rest, %{apply_event(st, ev) | seq: seq, tag: tag})
    end
  rescue
    _ -> {:error, :journal_corrupt}
  end

  defp replay(_h, _garbage, _st), do: {:error, :journal_corrupt}

  # Trust boundary: journal/head bodies are `[:safe]`-decoded and then
  # shape-validated ({seq, prev, ev} / {seq, tag}) below, so a corrupt or
  # hostile file fails closed to `:journal_corrupt` instead of minting atoms
  # or deserializing funs.
  # sobelow_skip ["Misc.BinToTerm"]
  defp decode(body) do
    case :erlang.binary_to_term(body, [:safe]) do
      {seq, prev, ev} when is_integer(seq) and is_binary(prev) -> {:ok, {seq, prev, ev}}
      _ -> {:error, :journal_corrupt}
    end
  rescue
    _ -> {:error, :journal_corrupt}
  end

  defp check_seq(seq, prev, st) do
    cond do
      seq != st.seq + 1 -> {:error, :journal_sequence_gap}
      prev != st.tag -> {:error, :prepared_authentication_failed}
      true -> :ok
    end
  end

  defp check_head(h, st) do
    case File.read(head_path(h)) do
      {:ok, <<blen::32, body::binary-size(blen), htag::binary>>} ->
        with :ok <- verify(h, body, htag),
             {:ok, {seq, _tag}} <- decode_head(body) do
          if st.seq < seq, do: {:error, :journal_truncated}, else: {:ok, st}
        end

      {:ok, _} ->
        {:error, :journal_corrupt}

      {:error, :enoent} ->
        if st.seq == 0, do: {:ok, st}, else: {:error, :journal_truncated}

      {:error, r} ->
        {:error, {:journal_io, r}}
    end
  end

  # sobelow_skip ["Misc.BinToTerm"]
  defp decode_head(body) do
    case :erlang.binary_to_term(body, [:safe]) do
      {seq, tag} when is_integer(seq) and is_binary(tag) -> {:ok, {seq, tag}}
      _ -> {:error, :journal_corrupt}
    end
  rescue
    _ -> {:error, :journal_corrupt}
  end

  defp mac(h, bytes) do
    {provider, opts} = h.key_provider
    KeyCustody.mac(provider, bytes, opts)
  end

  defp verify(h, bytes, tag) do
    {provider, opts} = h.key_provider

    case KeyCustody.verify(provider, bytes, tag, opts) do
      :ok -> :ok
      {:error, :prepared_key_unavailable} = e -> e
      _ -> {:error, :prepared_authentication_failed}
    end
  end

  # -- cross-process lock --

  defp with_lock(h, fun) do
    with :ok <- ensure_dir(h),
         {:ok, lock} <- acquire(Path.join(h.dir, "lock"), System.monotonic_time(:millisecond)) do
      try do
        fun.()
      after
        File.rmdir(lock)
      end
    end
  end

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
            {:error, :journal_lock_timeout}

          true ->
            Process.sleep(2)
            acquire(lock, started)
        end

      {:error, r} ->
        {:error, {:journal_io, r}}
    end
  end

  defp stale?(lock) do
    case File.stat(lock, time: :posix) do
      {:ok, %{mtime: m}} -> System.os_time(:second) - m > @lock_stale_s
      _ -> false
    end
  end
end
