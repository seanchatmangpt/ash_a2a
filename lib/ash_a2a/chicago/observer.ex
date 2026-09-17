defmodule AshA2A.Chicago.Observer do
  @moduledoc """
  Independent process observer for a Chicago run (RFC-SA2A-002 §7, §15-§21,
  §107, §108, §138, §139).

  Attaches `:telemetry` handlers for every event named by the run's admitted
  `AshA2A.Chicago.Ocel.Mapping`s, the court stimulus events and any
  `:watch_events`, records what the real SUT emits, journals it durably, and
  flushes it as a content-addressed OCEL 2.0 JSON artifact.

  Qualified by `AshA2A.Chicago.Courts.ObserverQualification`.

  ## Evidence discipline

    * **Source independence** -- consumes telemetry the SUT emits at its own
      boundaries, never an actuator's return value (§8, §18).
    * **Ordering (§20)** -- every record carries its own node-wide monotonic
      sequence number (`chicago_seq`) taken in the emitting process at
      emission, so two records never share an identity (one event mapped by
      two admitted mappings yields two records). Artifacts are ordered by
      `chicago_seq`, and falsifier attribution is by sequence interval between
      a stimulus's start and stop records -- never by the order in which
      deliveries happened to arrive.
    * **No silent loss (§138)** -- the handler never raises (telemetry would
      detach it). A record whose synchronous delivery fails (observer dead,
      suspended past `:delivery_timeout_ms`, stopped) increments the drop
      counter and emits `[:ash_a2a, :chicago, :observer, :dropped]`. A record
      accepted after its delivery deadline is kept and marked
      `chicago_late_delivery`. Dropped records and restart gaps are flushed
      with the artifact and block `CONFORMANT` standing.
    * **Relationship identity (§107, §138)** -- object references are
      validated (`Mapping.resolve_objects/3`); malformed, colliding or
      reserved references are dropped, flagged on the record
      (`chicago_rejected_refs`) and emitted as
      `[:ash_a2a, :chicago, :observer, :ref_rejected]`, never fabricated.
      A mapping cannot set attributes in the reserved `chicago_` namespace.
    * **Unknown types** -- an attached event with no admitted mapping
      (`:watch_events`) becomes a typed `chicago.unmapped` event carrying its
      telemetry name and scalar metadata, plus
      `[:ash_a2a, :chicago, :observer, :unmapped]`; unknown object types from
      a mapping are preserved and declared.
    * **Durability and restart recovery (§19)** -- with `:journal`, every
      accepted record is appended to an append-only, line-hashed JSONL journal
      (`AshA2A.Chicago.Observer.Journal`, which documents the fsync policy)
      before the delivery is acknowledged. Starting an observer over an
      existing journal (or with `restart: true`) is a *recovery incarnation*:
      it restores every intact record, harvests the drop counters of dead
      incarnations' still-attached handlers, counts corrupt, torn and
      duplicate journal lines as lost evidence, and records a
      `chicago.observer.gap` event -- it marks the discontinuity instead of
      pretending continuity.
    * **Non-authority (§108)** -- the observer records; it holds no capability
      and its code closure has no consequence call site
      (`AshA2A.Chicago.Observer.NonAuthority`).
    * **No self-recursion** -- an observer's own boundary telemetry is never
      ingested by that observer's handler, and no boundary telemetry is
      emitted while handling a boundary event, so observers watching each
      other cannot loop.
  """

  use GenServer

  alias AshA2A.Chicago.Context
  alias AshA2A.Chicago.Observer.{EvidenceBounds, Journal}
  alias AshA2A.Chicago.Ocel.{Log, Mapping}

  @type record :: %{
          seq: pos_integer(),
          event: [atom() | String.t()],
          activity: String.t(),
          time_us: integer(),
          attributes: %{String.t() => Mapping.scalar()},
          objects: [Mapping.object_ref()],
          falsifier_id: String.t() | nil,
          court_id: String.t() | nil,
          run_id: String.t() | nil
        }

  @type flush_result :: %{
          path: Path.t(),
          sha256: String.t(),
          bytes: non_neg_integer(),
          events: non_neg_integer(),
          objects: non_neg_integer(),
          dropped: non_neg_integer(),
          gaps: non_neg_integer(),
          late: non_neg_integer(),
          unmapped: non_neg_integer(),
          rejected_refs: non_neg_integer(),
          incarnation: pos_integer(),
          ordered: boolean(),
          identity_unique: boolean(),
          journal: Path.t() | nil,
          mapping_digest: String.t()
        }

  @stimulus_start [:ash_a2a, :chicago, :stimulus, :start]
  @stimulus_stop [:ash_a2a, :chicago, :stimulus, :stop]
  @boundary [:ash_a2a, :chicago, :observer]
  @gap_activity "chicago.observer.gap"
  @unmapped_activity "chicago.unmapped"
  @default_delivery_timeout_ms 5_000
  @max_unmapped_attributes 32

  @doc """
  Starts a linked observer. Options:

    * `:run_id` (required)
    * `:mappings` -- admitted `Mapping`s
    * `:watch_events` -- events observed without a mapping (typed `chicago.unmapped`)
    * `:journal` -- journal path (see `journal_path/2`); enables durability and recovery
    * `:journal_sync` -- `Journal` fsync policy (default `{:every, 32}`)
    * `:delivery_timeout_ms` -- per-record synchronous delivery bound (default 5000)
    * `:restart` -- start as a recovery incarnation even without a journal
    * `:owner` -- pid; the observer stops when it exits
    * `:name`
    * `:evidence_bounds` -- an `AshA2A.Chicago.Observer.EvidenceBounds.t()`
      (PRD §48 / ARD §51). Optional and strictly additive: omitted, the
      observer is unbounded exactly as before. When given, the configured
      `:watch_events` vocabulary is admitted against `max_watch_events` at
      start (refusing startup, `{:stop, {:evidence_fan_out_exceeded, _}}`,
      if the configured vocabulary itself is already too wide), and every
      accepted record thereafter is charged against `max_records` and
      `max_journal_bytes`; a record past either ceiling is refused rather
      than accepted, and a typed
      `[:ash_a2a, :chicago, :observer, :evidence_bounds_exceeded]` boundary
      event is emitted in its place (never silently dropped).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, gen_opts(opts))

  @doc "Starts an unlinked observer (same options as `start_link/1`)."
  @spec start(keyword()) :: GenServer.on_start()
  def start(opts), do: GenServer.start(__MODULE__, opts, gen_opts(opts))

  defp gen_opts(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} -> [name: name]
      :error -> []
    end
  end

  @doc "Records so far, attributed and ordered by `chicago_seq`."
  @spec records(GenServer.server()) :: [record()]
  def records(observer), do: GenServer.call(observer, :records)

  @spec records_for(GenServer.server(), String.t()) :: [record()]
  def records_for(observer, falsifier_id),
    do: GenServer.call(observer, {:records_for, falsifier_id})

  @doc "Dropped records: this incarnation, dead incarnations, corrupt journal lines."
  @spec dropped(GenServer.server()) :: non_neg_integer()
  def dropped(observer), do: GenServer.call(observer, :dropped)

  @spec mapping_digest(GenServer.server()) :: String.t()
  def mapping_digest(observer), do: GenServer.call(observer, :mapping_digest)

  @doc "Every telemetry event this observer is attached to."
  @spec watched_events(GenServer.server()) :: [[atom()]]
  def watched_events(observer), do: GenServer.call(observer, :watched_events)

  @doc "Evidence-quality counters of this observer incarnation."
  @spec stats(GenServer.server()) :: map()
  def stats(observer), do: GenServer.call(observer, :stats)

  @doc """
  Writes `ocel.json` into `dir` (created if needed), fsyncs it, and returns
  its content digest and evidence counters. The artifact survives the
  observer and the producer process (§19).
  """
  @spec flush(GenServer.server(), Path.t()) :: {:ok, flush_result()} | {:error, term()}
  def flush(observer, dir), do: GenServer.call(observer, {:flush, dir}, 60_000)

  @spec stop(GenServer.server()) :: :ok
  def stop(observer), do: GenServer.stop(observer, :normal)

  @doc "Journal path for `run_id` under an evidence directory."
  @spec journal_path(Path.t(), String.t()) :: Path.t()
  def journal_path(dir, run_id) do
    safe = String.replace(run_id, ~r/[^A-Za-z0-9._-]/, "_")
    Path.join(dir, "ocel-journal-#{safe}.jsonl")
  end

  @doc """
  Returns `observer` when it is alive; otherwise starts an unlinked recovery
  incarnation with `opts` (journal recovery + gap record) and returns it.
  """
  @spec ensure_running(pid() | nil, keyword()) :: pid()
  def ensure_running(observer, opts) do
    if is_pid(observer) and Process.alive?(observer) do
      observer
    else
      {:ok, pid} = start(Keyword.put(opts, :restart, true))
      pid
    end
  end

  @doc """
  Stops every live incarnation of `run_id` and detaches the handlers of dead
  ones (a killed observer never runs `terminate/2`).
  """
  @spec stop_run(String.t()) :: :ok
  def stop_run(run_id) do
    for %{id: id, config: config} <- run_handlers(run_id) do
      observer = config[:observer]

      if is_pid(observer) and observer != self() and Process.alive?(observer) do
        try do
          GenServer.stop(observer, :normal, 10_000)
        catch
          :exit, _ -> :ok
        end
      end

      :telemetry.detach(id)
    end

    :ok
  end

  @doc "Telemetry events the observer itself emits."
  @spec boundary_events() :: [[atom()]]
  def boundary_events do
    for suffix <- [
          :dropped,
          :ref_rejected,
          :unmapped,
          :recovered,
          :flushed,
          :evidence_bounds_exceeded
        ],
        do: @boundary ++ [suffix]
  end

  @doc "Globally-unique OCEL object id for `(type, id)`."
  @spec oid(String.t(), String.t()) :: String.t()
  def oid(type, id), do: type <> ":" <> id

  # --- telemetry handler (runs in the EMITTING process) -------------------

  @doc false
  def handle_event(event, measurements, metadata, config) do
    metadata = if is_map(metadata), do: metadata, else: %{}

    cond do
      self() == config.observer ->
        :ok

      boundary_event?(event) and Map.get(metadata, :observer_ref) == config.ref ->
        :ok

      true ->
        measurements = if is_map(measurements), do: measurements, else: %{}

        event
        |> build_records(measurements, metadata, config)
        |> Enum.each(&deliver(&1, event, config))
    end

    :ok
  rescue
    _ ->
      if is_map(config) and Map.has_key?(config, :counters),
        do: :counters.add(config.counters, 1, 1)

      :ok
  end

  defp build_records(@stimulus_start, measurements, metadata, config),
    do: [
      stimulus_record(@stimulus_start, "chicago.stimulus.start", measurements, metadata, config)
    ]

  defp build_records(@stimulus_stop, measurements, metadata, config),
    do: [stimulus_record(@stimulus_stop, "chicago.stimulus.stop", measurements, metadata, config)]

  defp build_records(event, measurements, metadata, config) do
    case Map.get(config.by_event, event, []) do
      [] -> [unmapped_record(event, measurements, metadata, config)]
      mappings -> Enum.map(mappings, &mapped_record(&1, event, measurements, metadata, config))
    end
  end

  defp mapped_record(%Mapping{} = mapping, event, measurements, metadata, config) do
    # Taken before any mapping code runs: the emission point, whatever
    # happens to delivery afterwards.
    seq = next_seq(config)
    time_us = System.system_time(:microsecond)
    {objects, rejected, object_error} = Mapping.resolve_objects(mapping, measurements, metadata)
    {attributes, attr_error} = Mapping.attributes(mapping, measurements, metadata)

    {reserved, attributes} =
      Map.split_with(attributes, fn {k, _} -> String.starts_with?(k, "chicago_") end)

    attributes =
      attributes
      |> maybe_put("chicago_mapping_error", object_error || attr_error)
      |> maybe_put(
        "chicago_reserved_attributes_dropped",
        map_size(reserved) > 0 && reserved |> Map.keys() |> Enum.sort() |> Enum.join(",")
      )
      |> put_rejected(rejected)

    unless boundary_event?(event) do
      for {reason, type} <- rejected do
        emit_from_handler(config, :ref_rejected, %{
          event: dotted(event),
          activity: mapping.activity,
          reason: reason,
          object_type: type
        })
      end
    end

    %{
      seq: seq,
      event: event,
      activity: mapping.activity,
      time_us: time_us,
      attributes: attributes,
      objects: objects,
      falsifier_id: nil,
      court_id: nil,
      run_id: nil
    }
  end

  defp put_rejected(attributes, []), do: attributes

  defp put_rejected(attributes, rejected) do
    reasons =
      rejected
      |> Enum.map(&Atom.to_string(elem(&1, 0)))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.join(",")

    attributes
    |> Map.put("chicago_rejected_refs", length(rejected))
    |> Map.put("chicago_rejected_ref_reasons", reasons)
  end

  defp unmapped_record(event, measurements, metadata, config) do
    seq = next_seq(config)
    time_us = System.system_time(:microsecond)

    attributes =
      [{"meta.", Map.delete(metadata, :observer_ref)}, {"measure.", measurements}]
      |> Enum.flat_map(fn {prefix, map} ->
        Enum.flat_map(map, fn {k, v} ->
          case Mapping.scalar(v) do
            nil -> []
            scalar -> [{prefix <> to_string(k), scalar}]
          end
        end)
      end)
      |> Enum.sort()
      |> Enum.take(@max_unmapped_attributes)
      |> Map.new()
      |> Map.put("chicago_unmapped", true)

    unless boundary_event?(event),
      do: emit_from_handler(config, :unmapped, %{event: dotted(event)})

    %{
      seq: seq,
      event: event,
      activity: @unmapped_activity,
      time_us: time_us,
      attributes: attributes,
      objects: [],
      falsifier_id: nil,
      court_id: nil,
      run_id: nil
    }
  end

  defp stimulus_record(event, activity, measurements, metadata, config) do
    seq = next_seq(config)

    attributes =
      %{}
      |> maybe_put("outcome", Mapping.scalar(Map.get(metadata, :outcome)))
      |> maybe_put("duration_us", Mapping.scalar(Map.get(measurements, :duration_us)))

    %{
      seq: seq,
      event: event,
      activity: activity,
      time_us: System.system_time(:microsecond),
      attributes: attributes,
      objects: [],
      falsifier_id: Map.get(metadata, :falsifier_id),
      court_id: Map.get(metadata, :court_id),
      run_id: Map.get(metadata, :run_id)
    }
  end

  defp deliver(record, event, config) do
    deadline = System.monotonic_time(:millisecond) + config.timeout
    GenServer.call(config.observer, {:record, record, deadline}, config.timeout)
  catch
    :exit, reason ->
      :counters.add(config.counters, 1, 1)

      unless boundary_event?(event) do
        emit_from_handler(config, :dropped, %{
          event: dotted(event),
          activity: record.activity,
          reason: exit_class(reason)
        })
      end

      :ok
  end

  defp exit_class({:timeout, _}), do: :timeout
  defp exit_class({:noproc, _}), do: :noproc
  defp exit_class({:calling_self, _}), do: :calling_self
  defp exit_class({reason, _}) when reason in [:normal, :shutdown], do: :observer_stopped
  defp exit_class({{:shutdown, _}, _}), do: :observer_stopped
  defp exit_class({:killed, _}), do: :killed
  defp exit_class(_), do: :exit

  defp emit_from_handler(config, suffix, meta) do
    :telemetry.execute(
      @boundary ++ [suffix],
      %{system_time: System.system_time()},
      Map.merge(meta, %{observer_run_id: config.run_id, observer_ref: config.ref})
    )
  end

  defp boundary_event?([:ash_a2a, :chicago, :observer | _]), do: true
  defp boundary_event?(_event), do: false

  defp next_seq(%{seq_offset: offset}),
    do: offset + System.unique_integer([:monotonic, :positive])

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, false), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp dotted(event) when is_list(event), do: Enum.map_join(event, ".", &to_string/1)
  defp dotted(event) when is_binary(event), do: event

  # --- GenServer -----------------------------------------------------------

  @impl true
  def init(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    journal_path = Keyword.get(opts, :journal)

    case read_journal(run_id, journal_path) do
      {:ok, recovered} -> start_incarnation(opts, run_id, journal_path, recovered)
      {:error, reason} -> {:stop, reason}
    end
  end

  defp start_incarnation(opts, run_id, journal_path, recovered) do
    mappings = Keyword.get(opts, :mappings, [])
    by_event = Enum.group_by(mappings, & &1.event)

    watch =
      opts
      |> Keyword.get(:watch_events, [])
      |> Enum.reject(&(Map.has_key?(by_event, &1) or &1 in Context.stimulus_events()))

    events = Enum.uniq(Context.stimulus_events() ++ Map.keys(by_event) ++ watch)

    case admit_watch_vocabulary(Keyword.get(opts, :evidence_bounds), watch) do
      {:ok, evidence_bounds} ->
        start_incarnation(
          opts,
          run_id,
          journal_path,
          recovered,
          mappings,
          by_event,
          events,
          evidence_bounds
        )

      {:error, reason} ->
        {:stop, {:evidence_fan_out_exceeded, reason}}
    end
  end

  # §48/§51 evidence-fan-out admission: the configured `:watch_events`
  # vocabulary is fixed for the observer's whole lifetime (attached once,
  # below), so it is admitted once, at start, rather than incrementally --
  # fail-closed at construction, mirroring `AshA2A.Semantic.Bounds.new/1`.
  defp admit_watch_vocabulary(nil, _watch), do: {:ok, nil}

  defp admit_watch_vocabulary(%EvidenceBounds{} = bounds, watch) do
    Enum.reduce_while(Enum.uniq(watch), {:ok, bounds}, fn event, {:ok, acc} ->
      case EvidenceBounds.admit_watch_event(acc, dotted(event)) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp start_incarnation(
         opts,
         run_id,
         journal_path,
         recovered,
         mappings,
         by_event,
         events,
         evidence_bounds
       ) do
    stale = run_handlers(run_id)
    incarnation = Enum.max([recovered.incarnations | Enum.map(stale, &elem(&1.id, 2))]) + 1
    counters = :counters.new(1, [:write_concurrency])
    ref = make_ref()
    handler_id = {__MODULE__, run_id, incarnation, ref}

    # Sequence numbers of a recovery incarnation start above every recovered
    # record, so ordering holds even when recovery happens in a fresh VM.
    seq_offset = recovered.records |> Enum.map(& &1.seq) |> Enum.max(fn -> 0 end)

    :ok =
      :telemetry.attach_many(handler_id, events, &__MODULE__.handle_event/4, %{
        observer: self(),
        ref: ref,
        run_id: run_id,
        by_event: by_event,
        counters: counters,
        seq_offset: seq_offset,
        timeout: Keyword.get(opts, :delivery_timeout_ms, @default_delivery_timeout_ms)
      })

    # Attach first, then harvest dead incarnations: no window with nobody attached.
    harvested = harvest(stale)
    restart? = Keyword.get(opts, :restart, false) or recovered.incarnations > 0 or stale != []

    prior_drops =
      recovered.drops
      |> Map.merge(harvested.drops, fn _inc, journaled, live -> max(journaled, live) end)
      |> Map.values()
      |> Enum.sum()

    if owner = Keyword.get(opts, :owner), do: Process.monitor(owner)

    state = %{
      run_id: run_id,
      ref: ref,
      handler_id: handler_id,
      events: events,
      incarnation: incarnation,
      seq_offset: seq_offset,
      mapping_digest: Mapping.digest(mappings),
      counters: counters,
      base_dropped: prior_drops + recovered.corrupt_lines,
      journaled_drops: 0,
      records: Map.new(recovered.records, &{&1.seq, &1}),
      duplicate_seqs: 0,
      journal: nil,
      journal_failures: 0,
      recovery:
        recovered |> Map.delete(:records) |> Map.put(:harvested_handlers, harvested.count),
      evidence_bounds: evidence_bounds,
      evidence_bounds_exceeded: 0
    }

    policy = Keyword.get(opts, :journal_sync, Journal.default_policy())

    case open_journal(state, journal_path, policy) do
      {:ok, state} ->
        {:ok, if(restart?, do: mark_gap(state, recovered, harvested, prior_drops), else: state)}

      {:error, reason} ->
        :telemetry.detach(handler_id)
        {:stop, {:journal_unavailable, reason}}
    end
  end

  defp read_journal(_run_id, nil), do: {:ok, empty_recovery()}

  defp read_journal(run_id, path) do
    case Journal.recover(path) do
      {:ok, %{run_ids: run_ids} = recovered} ->
        case Enum.reject(run_ids, &(&1 == run_id)) do
          [] -> {:ok, recovered}
          other -> {:error, {:journal_run_mismatch, expected: run_id, found: other}}
        end

      {:error, :enoent} ->
        {:ok, empty_recovery()}

      {:error, reason} ->
        {:error, {:journal_unreadable, reason}}
    end
  end

  defp empty_recovery do
    %{
      run_ids: [],
      incarnations: 0,
      records: [],
      drops: %{},
      corrupt_lines: 0,
      duplicate_lines: 0,
      torn_tail: false,
      lines: 0
    }
  end

  defp run_handlers(run_id) do
    []
    |> :telemetry.list_handlers()
    |> Enum.uniq_by(& &1.id)
    |> Enum.filter(&match?(%{id: {__MODULE__, ^run_id, _inc, _ref}}, &1))
  end

  # Detaches the handlers of dead incarnations of this run and reads the drop
  # counters they accumulated while nobody was receiving. The count is a
  # lower bound (an emitter already inside a stale handler as it is detached
  # can still add to a counter nobody reads again); the gap record is what
  # blocks standing regardless of the count.
  defp harvest(stale) do
    dead =
      Enum.reject(stale, fn %{config: config} ->
        is_pid(config[:observer]) and Process.alive?(config.observer)
      end)

    Enum.each(dead, &:telemetry.detach(&1.id))

    %{
      count: length(dead),
      drops:
        Map.new(dead, fn %{id: {_, _, inc, _}, config: config} ->
          {inc, :counters.get(config.counters, 1)}
        end)
    }
  end

  defp open_journal(state, nil, _policy), do: {:ok, state}

  defp open_journal(state, path, policy) do
    with {:ok, journal} <- Journal.open(path, policy),
         {:ok, journal} <-
           Journal.append(journal, %{
             "kind" => "header",
             "schema" => Journal.schema(),
             "run_id" => state.run_id,
             "incarnation" => state.incarnation,
             "mapping_digest" => state.mapping_digest
           }) do
      {:ok, %{state | journal: journal}}
    end
  end

  defp mark_gap(state, recovered, harvested, prior_drops) do
    recovered_records = map_size(state.records)

    gap = %{
      seq: next_seq(state),
      event: @boundary ++ [:gap],
      activity: @gap_activity,
      time_us: System.system_time(:microsecond),
      attributes: %{
        "incarnation" => state.incarnation,
        "recovered_records" => recovered_records,
        "dropped_before_restart" => prior_drops,
        "dead_incarnation_handlers" => harvested.count,
        "corrupt_journal_lines" => recovered.corrupt_lines,
        "duplicate_journal_lines" => recovered.duplicate_lines,
        "torn_journal_tail" => recovered.torn_tail,
        "journal_present" => state.journal != nil,
        "continuity" => "broken"
      },
      objects: [],
      falsifier_id: nil,
      court_id: nil,
      run_id: state.run_id
    }

    state = state |> accept(gap) |> journal_sync()

    emit_boundary(state, :recovered, %{
      incarnation: state.incarnation,
      recovered_records: recovered_records,
      gaps: gap_count(state),
      dropped: dropped_total(state),
      dropped_while_down: harvested.drops |> Map.values() |> Enum.sum(),
      corrupt_lines: recovered.corrupt_lines,
      duplicate_lines: recovered.duplicate_lines,
      torn_tail: recovered.torn_tail
    })

    state
  end

  @impl true
  def handle_call({:record, record, deadline}, _from, state) do
    cond do
      record.activity in ["chicago.stimulus.start", "chicago.stimulus.stop"] and
          record.run_id != state.run_id ->
        {:reply, :ok, state}

      Map.has_key?(state.records, record.seq) ->
        {:reply, :ok, %{state | duplicate_seqs: state.duplicate_seqs + 1}}

      true ->
        record =
          if System.monotonic_time(:millisecond) > deadline,
            do: %{record | attributes: Map.put(record.attributes, "chicago_late_delivery", true)},
            else: record

        case admit_evidence(state, record) do
          {:ok, state} ->
            state = state |> accept(record) |> journal_drops()

            state =
              if record.activity == "chicago.stimulus.stop", do: journal_sync(state), else: state

            {:reply, :ok, state}

          {:error, reason} ->
            {:reply, :ok, evidence_exceeded(state, record, reason)}
        end
    end
  end

  def handle_call(:records, _from, state), do: {:reply, attributed(state), state}

  def handle_call({:records_for, id}, _from, state),
    do: {:reply, state |> attributed() |> Enum.filter(&(&1.falsifier_id == id)), state}

  def handle_call(:dropped, _from, state), do: {:reply, dropped_total(state), state}
  def handle_call(:mapping_digest, _from, state), do: {:reply, state.mapping_digest, state}
  def handle_call(:watched_events, _from, state), do: {:reply, state.events, state}

  def handle_call(:stats, _from, state) do
    records = Map.values(state.records)

    stats = %{
      run_id: state.run_id,
      incarnation: state.incarnation,
      records: length(records),
      dropped: dropped_total(state),
      gaps: gap_count(state),
      late: Enum.count(records, &(&1.attributes["chicago_late_delivery"] == true)),
      unmapped: Enum.count(records, &(&1.activity == @unmapped_activity)),
      rejected_refs: rejected_total(records),
      duplicate_seqs: state.duplicate_seqs,
      corrupt_journal_lines: state.recovery.corrupt_lines,
      duplicate_journal_lines: state.recovery.duplicate_lines,
      torn_journal_tail: state.recovery.torn_tail,
      harvested_handlers: state.recovery.harvested_handlers,
      journal: state.journal && state.journal.path,
      journal_failures: state.journal_failures,
      evidence_bounds_exceeded: state.evidence_bounds_exceeded,
      evidence_bounds: state.evidence_bounds && EvidenceBounds.snapshot(state.evidence_bounds)
    }

    {:reply, stats, state}
  end

  def handle_call({:flush, dir}, _from, state) do
    {reply, state} = state |> journal_drops() |> write_artifact(dir)
    {:reply, reply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _owner, _reason}, state), do: {:stop, :normal, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :telemetry.detach(state.handler_id)

    if state.journal do
      state = journal_drops(state)

      state =
        journal_append(state, %{
          "kind" => "close",
          "incarnation" => state.incarnation,
          "dropped" => dropped_total(state)
        })

      Journal.close(state.journal)
    end

    :ok
  end

  # --- state helpers -------------------------------------------------------

  # §48/§51 evidence-fan-out admission (PRD §48 / ARD §51): charges the
  # about-to-be-accepted record against the run's `EvidenceBounds` envelope,
  # if one was configured. `nil` means unbounded, unchanged from before this
  # envelope existed. Journal-byte cost is measured from the exact canonical
  # JSONL line the record would produce, so the ceiling tracks the real
  # attribute payload rather than an estimate.
  defp admit_evidence(%{evidence_bounds: nil} = state, _record), do: {:ok, state}

  defp admit_evidence(%{evidence_bounds: bounds} = state, record) do
    bytes = record |> Journal.record_entry() |> Journal.encode_line() |> IO.iodata_length()

    with {:ok, bounds} <- EvidenceBounds.consume_record(bounds),
         {:ok, bounds} <- EvidenceBounds.consume_journal_bytes(bounds, bytes) do
      {:ok, %{state | evidence_bounds: bounds}}
    end
  end

  # A record refused by the evidence envelope is never silently lost: it is
  # counted (`evidence_bounds_exceeded`, visible in `stats/1`) and emitted as
  # a typed boundary event, the same "no silent loss" discipline §138 applies
  # to delivery drops -- just refused rather than accepted, since growing the
  # OCEL artifact past an admitted ceiling is exactly what this envelope
  # exists to fail closed against.
  defp evidence_exceeded(state, record, %{code: code, detail: detail}) do
    state = %{state | evidence_bounds_exceeded: state.evidence_bounds_exceeded + 1}

    emit_boundary(state, :evidence_bounds_exceeded, %{
      event: dotted(record.event),
      activity: record.activity,
      code: code,
      resource: detail[:resource],
      ceiling: detail[:ceiling],
      consumed: detail[:consumed]
    })

    state
  end

  defp accept(state, record) do
    state
    |> journal_append(Journal.record_entry(record))
    |> Map.update!(:records, &Map.put(&1, record.seq, record))
  end

  defp journal_append(%{journal: nil} = state, _entry), do: state

  defp journal_append(state, entry) do
    case Journal.append(state.journal, entry) do
      {:ok, journal} -> %{state | journal: journal}
      {:error, _reason} -> %{state | journal_failures: state.journal_failures + 1}
    end
  end

  defp journal_sync(%{journal: nil} = state), do: state

  defp journal_sync(state) do
    case Journal.sync(state.journal) do
      {:ok, journal} -> %{state | journal: journal}
      {:error, _reason} -> %{state | journal_failures: state.journal_failures + 1}
    end
  end

  defp journal_drops(state) do
    current = :counters.get(state.counters, 1)

    if state.journal != nil and current > state.journaled_drops do
      state
      |> journal_append(%{
        "kind" => "drops",
        "incarnation" => state.incarnation,
        "total" => current
      })
      |> Map.put(:journaled_drops, current)
    else
      state
    end
  end

  defp dropped_total(state), do: state.base_dropped + :counters.get(state.counters, 1)

  defp gap_count(state),
    do: state.records |> Map.values() |> Enum.count(&(&1.activity == @gap_activity))

  defp rejected_total(records) do
    records
    |> Enum.map(&Map.get(&1.attributes, "chicago_rejected_refs", 0))
    |> Enum.filter(&is_integer/1)
    |> Enum.sum()
  end

  defp emit_boundary(state, suffix, meta) do
    :telemetry.execute(
      @boundary ++ [suffix],
      %{system_time: System.system_time()},
      Map.merge(meta, %{
        observer_run_id: state.run_id,
        observer_ref: state.ref,
        observer_incarnation: state.incarnation
      })
    )
  end

  defp attributed(state) do
    state.records
    |> Map.values()
    |> Enum.sort_by(& &1.seq)
    |> attribute()
  end

  @doc """
  Attribution by sequence interval (§20) over records sorted by
  `chicago_seq`: a record belongs to the falsifier whose stimulus start
  precedes it and whose stop does not. A gap closes any open interval, since
  the stop may have been lost.
  """
  @spec attribute([record()]) :: [record()]
  def attribute(sorted_records) do
    {records, _active} =
      Enum.map_reduce(sorted_records, nil, fn
        %{activity: "chicago.stimulus.start"} = r, _active ->
          {r, {r.falsifier_id, r.court_id}}

        %{activity: "chicago.stimulus.stop"} = r, _active ->
          {r, nil}

        %{activity: @gap_activity} = r, _active ->
          {%{r | falsifier_id: nil, court_id: nil}, nil}

        r, nil ->
          {%{r | falsifier_id: nil, court_id: nil}, nil}

        r, {falsifier_id, court_id} = active ->
          {%{r | falsifier_id: falsifier_id, court_id: court_id}, active}
      end)

    records
  end

  defp write_artifact(state, dir) do
    records = attributed(state)
    seqs = Enum.map(records, & &1.seq)

    summary = %{
      dropped: dropped_total(state),
      gaps: gap_count(state),
      late: Enum.count(records, &(&1.attributes["chicago_late_delivery"] == true)),
      unmapped: Enum.count(records, &(&1.activity == @unmapped_activity)),
      rejected_refs: rejected_total(records),
      incarnation: state.incarnation,
      ordered: strictly_increasing?(seqs),
      identity_unique: state.duplicate_seqs == 0 and length(Enum.uniq(seqs)) == length(seqs)
    }

    log = build_log(records, state, summary)
    json = Log.encode(log)
    path = Path.join(dir, "ocel.json")

    with :ok <- File.mkdir_p(dir),
         :ok <- durable_write(path, json) do
      sha = :crypto.hash(:sha256, json) |> Base.encode16(case: :lower)

      result =
        Map.merge(summary, %{
          path: path,
          sha256: sha,
          bytes: byte_size(json),
          events: length(records),
          objects: map_size(log.objects),
          journal: state.journal && state.journal.path,
          mapping_digest: state.mapping_digest
        })

      state =
        state
        |> journal_append(%{"kind" => "flush", "sha256" => sha, "events" => result.events})
        |> journal_sync()

      emit_boundary(
        state,
        :flushed,
        Map.take(result, [
          :sha256,
          :events,
          :objects,
          :dropped,
          :gaps,
          :late,
          :unmapped,
          :rejected_refs,
          :incarnation,
          :ordered,
          :identity_unique
        ])
      )

      {{:ok, result}, state}
    else
      error -> {error, state}
    end
  rescue
    exception -> {{:error, {:ocel_write_failed, Exception.message(exception)}}, state}
  end

  defp strictly_increasing?(seqs),
    do: seqs |> Enum.chunk_every(2, 1, :discard) |> Enum.all?(fn [a, b] -> a < b end)

  defp durable_write(path, iodata) do
    case File.open(path, [:write, :binary, :raw]) do
      {:ok, io} ->
        try do
          with :ok <- :file.write(io, iodata), do: :file.sync(io)
        after
          File.close(io)
        end

      error ->
        error
    end
  end

  defp build_log(records, state, summary) do
    run_oid = oid("chicago_run", state.run_id)

    log =
      Log.new()
      |> Log.put_object("chicago_run", run_oid, %{
        "run_id" => state.run_id,
        "mapping_digest" => state.mapping_digest,
        "observer_incarnation" => summary.incarnation,
        "observer_dropped_records" => summary.dropped,
        "observer_gaps" => summary.gaps,
        "observer_late_records" => summary.late,
        "observer_unmapped_events" => summary.unmapped,
        "observer_rejected_refs" => summary.rejected_refs
      })

    Enum.reduce(records, log, fn record, log ->
      {log, rels} =
        Enum.reduce(record.objects, {log, []}, fn {type, id, qualifier}, {log, rels} ->
          object_id = oid(type, id)
          {Log.put_object(log, type, object_id), [{object_id, qualifier} | rels]}
        end)

      {log, rels} =
        case record.falsifier_id do
          nil ->
            {log, rels}

          fid ->
            f_oid = oid("falsifier", fid)
            c_oid = oid("court", record.court_id || "unknown")

            log =
              log
              |> Log.put_object("falsifier", f_oid, %{"falsifier_id" => fid})
              |> Log.put_object("court", c_oid, %{"court_id" => record.court_id || "unknown"})
              |> Log.relate_objects(f_oid, c_oid, "declared_by")
              |> Log.relate_objects(c_oid, run_oid, "executed_in")

            {log, [{c_oid, "court"}, {f_oid, "under_stimulus"} | rels]}
        end

      attributes =
        record.attributes
        |> Map.put("chicago_seq", record.seq)
        |> Map.put("telemetry_event", dotted(record.event))

      Log.add_event(log, %{
        id: "e-#{record.seq}",
        type: record.activity,
        time: record.time_us,
        attributes: attributes,
        relationships: Enum.reverse([{run_oid, "observed_in"} | rels])
      })
    end)
  end
end
