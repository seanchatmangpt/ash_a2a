defmodule Actuator.Store do
  @moduledoc """
  The actuator's durable effect-claim store and the ONE atomic transition.

  A single GenServer owns `<state_dir>/journal.jsonl` (append-only, fsync'd JSON lines) and
  the effect ledger. `execute/3` runs, inside one call and therefore serially:

      fence (16 checks) -> write-ahead `executing` (fsync) -> perform -> `completed` (fsync)

  The claim is a compare-and-set: it is written only if the instance's record is still
  exactly what the fence saw. On boot every record left `executing` becomes
  `unknown_outcome` (a crash between write-ahead and completion); an `unknown_outcome`
  instance is NEVER retried. `reconcile/4` is the only exit. Replay of the same
  certificate returns the recorded evidence and performs nothing.
  """
  use GenServer
  alias Actuator.{Anchor, Effect, EffectorRegistry, Fence, Journal, Ledger, StateLock}

  @fault Application.compile_env(:actuator, :fault_hook, false)

  # -- API ---------------------------------------------------------------

  def start_link(opts) do
    gen_opts = if n = opts[:name], do: [name: n], else: []
    GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :state_dir), gen_opts)
  end

  @doc "Run the fence and, if it passes, perform exactly one typed effect."
  @spec execute(GenServer.server(), Actuator.Context.t(), Fence.Request.t()) ::
          {:ok, %{status: :performed | :replayed, evidence: map()}}
          | {:error, pos_integer() | atom(), atom()}
  def execute(server, ctx, %Fence.Request{} = req),
    do: GenServer.call(server, {:execute, ctx, req}, 30_000)

  @doc "The only exit from `unknown_outcome`: an explicit, journaled resolution."
  def reconcile(server, instance_id, resolution, note)
      when resolution in [:confirmed_performed, :confirmed_not_performed],
      do: GenServer.call(server, {:reconcile, instance_id, resolution, note})

  def status(server, instance_id), do: GenServer.call(server, {:status, instance_id})
  def snapshot(server), do: GenServer.call(server, :snapshot)

  # -- server ------------------------------------------------------------

  @impl true
  def init(dir) do
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    Process.flag(:trap_exit, true)

    case StateLock.acquire(dir) do
      :ok ->
        case boot(dir) do
          {:ok, _} = ok ->
            ok

          stop ->
            StateLock.release(dir)
            stop
        end

      {:error, reason} ->
        {:stop, {:store_boot_refused, reason}}
    end
  end

  @impl true
  def terminate(_reason, %{dir: dir}), do: StateLock.release(dir)
  def terminate(_reason, _), do: :ok

  defp boot(dir) do
    jpath = Path.join(dir, "journal.jsonl")
    File.touch!(jpath)
    Ledger.trim_torn_tail(jpath)

    with {:ok, ledger} <- Ledger.open(dir),
         entries = Ledger.read(dir),
         {:ok, j} <- Journal.verify(jpath),
         :ok <- Anchor.check(dir, j.hashes, Enum.map(entries, & &1["hash"])),
         :ok <- Journal.cross_check(j.events, entries),
         {:ok, fd} <- :file.open(jpath, [:append, :binary, :raw]) do
      {records, nonce_owner} = fold(j.events)

      st = %{
        dir: dir,
        fd: fd,
        ledger: ledger,
        records: records,
        nonce_owner: nonce_owner,
        jseq: j.count,
        jhead: j.head
      }

      st = mark_unknown_on_restart(st)

      case Anchor.write(dir, anchor_fields(st)) do
        :ok -> {:ok, st}
        {:error, reason} -> {:stop, {:store_boot_refused, {:anchor_unwritable, reason}}}
      end
    else
      {:error, reason} -> {:stop, {:store_boot_refused, reason}}
    end
  end

  @impl true
  def handle_call({:execute, ctx, req}, _from, st) do
    id = req.effect.effect_instance_id
    seen = Map.get(st.records, id)
    view = %{record: seen, nonce_owner: st.nonce_owner}

    case Fence.run(ctx, req, view) do
      :ok ->
        do_execute(ctx, req, seen, st)

      {:error, _n, code} = refusal
      when code in [:effect_already_completed, :unknown_outcome, :claim_closed] ->
        if seen.effect_digest == req.cert.effect_digest and seen.generation == req.cert.generation do
          {:reply, {:ok, %{status: :replayed, evidence: evidence(seen)}}, st}
        else
          {:reply, refusal, st}
        end

      refusal ->
        {:reply, refusal, st}
    end
  end

  def handle_call({:reconcile, id, resolution, note}, _from, st) do
    case Map.get(st.records, id) do
      %{state: :unknown_outcome} = rec ->
        new =
          if resolution == :confirmed_performed, do: :completed, else: :reconciled_not_performed

        ev = %{
          "t" => "reconciled",
          "instance_id" => id,
          "resolution" => Atom.to_string(resolution),
          "note" => note,
          "at" => System.os_time(:second)
        }

        case journal(st, ev) do
          {:ok, st} ->
            rec = %{rec | state: new}
            {:reply, {:ok, evidence(rec)}, %{st | records: Map.put(st.records, id, rec)}}

          {{:error, _}, st} ->
            {:reply, {:error, :journal_unavailable}, st}
        end

      nil ->
        {:reply, {:error, :unknown_instance}, st}

      _ ->
        {:reply, {:error, :not_unknown_outcome}, st}
    end
  end

  def handle_call({:status, id}, _from, st) do
    {:reply,
     case Map.get(st.records, id) do
       nil -> :not_found
       r -> {:ok, evidence(r)}
     end, st}
  end

  def handle_call(:snapshot, _from, st), do: {:reply, st.records, st}

  @impl true
  def handle_info({:EXIT, _port, _reason}, st), do: {:noreply, st}
  def handle_info(_msg, st), do: {:noreply, st}

  # -- execution -----------------------------------------------------------

  defp do_execute(ctx, req, seen, st) do
    _ = ctx
    eff = req.effect
    id = eff.effect_instance_id
    digest = req.cert.effect_digest
    nonces = Enum.map(req.cert.signatures, &[&1.kid, &1.nonce])

    # compare-and-set: the record must still be exactly what the fence observed
    cond do
      Map.get(st.records, id) != seen ->
        {:reply, {:error, 14, :claim_conflict}, st}

      # No new claim while the anchor cannot be brought current: refuse before anything durable.
      Anchor.write(st.dir, anchor_fields(st)) != :ok ->
        {:reply, {:error, 14, :journal_unavailable}, st}

      true ->
        claim_and_perform(req, seen, eff, id, digest, nonces, st)
    end
  end

  defp claim_and_perform(req, _seen, eff, id, digest, nonces, st) do
    claim = %{
      "t" => "executing",
      "instance_id" => id,
      "generation" => req.cert.generation,
      "effect_digest" => digest,
      "nonces" => nonces,
      "at" => System.os_time(:second)
    }

    case journal(st, claim) do
      {{:error, _}, st} ->
        {:reply, {:error, 14, :journal_unavailable}, st}

      {:ok, st} ->
        rec = %{
          instance_id: id,
          state: :executing,
          generation: req.cert.generation,
          effect_digest: digest,
          ledger_seq: nil,
          ledger_hash: nil,
          at: claim["at"]
        }

        st = %{
          st
          | records: Map.put(st.records, id, rec),
            nonce_owner:
              Enum.reduce(nonces, st.nonce_owner, fn [k, n], m -> Map.put(m, {k, n}, id) end)
        }

        fault(:after_write_ahead)
        perform(eff, digest, rec, st)
    end
  end

  defp perform(eff, digest, rec, st) do
    {:ok, spec} = EffectorRegistry.fetch(eff.effect_type)

    result =
      try do
        spec.module.perform(%{ledger: st.ledger}, eff, digest)
      rescue
        e -> {:error, {:raised, Exception.message(e)}}
      end

    fault(:after_perform)
    id = rec.instance_id

    case result do
      {:ok, out} ->
        st = if l = out[:ledger], do: %{st | ledger: l}, else: st
        done = %{rec | state: :completed, ledger_seq: out[:seq], ledger_hash: out[:hash]}

        ev = %{
          "t" => "completed",
          "instance_id" => id,
          "ledger_seq" => out[:seq],
          "ledger_hash" => out[:hash],
          "at" => System.os_time(:second)
        }

        # anchor the ledger head as soon as the effect is durable, before the completion record
        _ = Anchor.write(st.dir, anchor_fields(st))

        case journal(st, ev) do
          {:ok, st} ->
            {:reply, {:ok, %{status: :performed, evidence: evidence(done)}},
             %{st | records: Map.put(st.records, id, done)}}

          {{:error, _}, st} ->
            unknown(st, rec, :completion_not_durable)
        end

      {:error, reason} ->
        unknown(st, rec, reason)
    end
  end

  defp unknown(st, rec, reason) do
    ev = %{
      "t" => "unknown_outcome",
      "instance_id" => rec.instance_id,
      "reason" => inspect(reason),
      "at" => System.os_time(:second)
    }

    {_, st} = journal(st, ev)
    rec = %{rec | state: :unknown_outcome}

    {:reply, {:error, :execution, :unknown_outcome},
     %{st | records: Map.put(st.records, rec.instance_id, rec)}}
  end

  # -- journal ---------------------------------------------------------------

  # Returns `{:ok | {:error, term}, state}`. The record is chained (seq/prev/hash), fsync'd,
  # and then the head anchor is replaced atomically (best effort, may lag). `{:error, _}` means
  # the append itself failed and the state is unchanged.
  defp journal(st, event) do
    {line, hash} = Journal.encode(event, st.jseq, st.jhead)

    with :ok <- :file.write(st.fd, line), :ok <- :file.sync(st.fd) do
      st = %{st | jseq: st.jseq + 1, jhead: hash}
      # The append is durable; an anchor failure only makes the anchor lag (allowed), and is
      # re-attempted before the next claim (see `do_execute/4`). It must never be reported as an
      # append failure.
      _ = Anchor.write(st.dir, anchor_fields(st))
      {:ok, st}
    else
      {:error, _} = e -> {e, st}
    end
  end

  defp anchor_fields(st),
    do: %{
      journal_seq: st.jseq,
      journal_head: st.jhead,
      ledger_seq: st.ledger.seq,
      ledger_head: st.ledger.head
    }

  defp fold(events) do
    events
    |> Enum.reduce({%{}, %{}}, fn ev, {recs, owners} ->
      id = ev["instance_id"]

      case ev["t"] do
        "executing" ->
          rec = %{
            instance_id: id,
            state: :executing,
            generation: ev["generation"],
            effect_digest: ev["effect_digest"],
            ledger_seq: nil,
            ledger_hash: nil,
            at: ev["at"]
          }

          {Map.put(recs, id, rec),
           Enum.reduce(ev["nonces"], owners, fn [k, n], m -> Map.put(m, {k, n}, id) end)}

        "completed" ->
          {Map.update!(
             recs,
             id,
             &%{
               &1
               | state: :completed,
                 ledger_seq: ev["ledger_seq"],
                 ledger_hash: ev["ledger_hash"]
             }
           ), owners}

        "unknown_outcome" ->
          {Map.update!(recs, id, &%{&1 | state: :unknown_outcome}), owners}

        "reconciled" ->
          new =
            if ev["resolution"] == "confirmed_performed",
              do: :completed,
              else: :reconciled_not_performed

          {Map.update!(recs, id, &%{&1 | state: new}), owners}
      end
    end)
  end

  defp mark_unknown_on_restart(st) do
    Enum.reduce(st.records, st, fn
      {id, %{state: :executing} = rec}, acc ->
        ev = %{
          "t" => "unknown_outcome",
          "instance_id" => id,
          "reason" => "restart_after_write_ahead",
          "at" => System.os_time(:second)
        }

        {:ok, acc} = journal(acc, ev)
        %{acc | records: Map.put(acc.records, id, %{rec | state: :unknown_outcome})}

      _, acc ->
        acc
    end)
  end

  def evidence(rec) do
    %{
      "effect_instance_id" => rec.instance_id,
      "effect_digest" => rec.effect_digest,
      "generation" => rec.generation,
      "state" => Atom.to_string(rec.state),
      "ledger_seq" => rec.ledger_seq,
      "ledger_hash" => rec.ledger_hash
    }
  end

  # Crash points exist ONLY when compiled with :fault_hook (test env). Used by the crash court.
  if @fault do
    defp fault(point) do
      if System.get_env("ACTUATOR_TEST_CRASH") == Atom.to_string(point),
        do: :erlang.halt(137, flush: false)

      :ok
    end
  else
    defp fault(_point), do: :ok
  end

  _ = Effect
end
