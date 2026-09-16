defmodule AshA2A.Chicago.Observer do
  @moduledoc """
  Independent process observer for a Chicago run (RFC-SA2A-002 §7, §15-§21,
  §108).

  Attaches `:telemetry` handlers for every event named by the run's admitted
  `AshA2A.Chicago.Ocel.Mapping`s plus the court stimulus events, records what
  the real SUT emits, and flushes it as a durable, content-addressed OCEL 2.0
  JSON artifact.

  Evidence discipline:

    * **Source independence** -- it consumes telemetry the SUT emits at its own
      boundaries, never an actuator's return value (§8, §18).
    * **Ordering** -- each record carries a node-wide monotonic sequence number
      taken in the emitting process (`chicago_seq`), so causal ordering never
      depends on wall clocks (§20).
    * **No silent loss** -- telemetry detaches a handler that raises; this
      handler never raises. A record that cannot be delivered increments the
      drop counter, which is flushed with the artifact and blocks standing
      when non-zero (§138).
    * **Non-authority** -- the observer records; it holds no capability and
      triggers nothing (§108).
  """

  use GenServer

  alias AshA2A.Chicago.Context
  alias AshA2A.Chicago.Ocel.{Log, Mapping}

  @type record :: %{
          seq: pos_integer(),
          event: [atom()],
          activity: String.t(),
          time_us: integer(),
          attributes: %{String.t() => Mapping.scalar()},
          objects: [Mapping.object_ref()],
          falsifier_id: String.t() | nil,
          court_id: String.t() | nil
        }

  @type flush_result :: %{
          path: Path.t(),
          sha256: String.t(),
          bytes: non_neg_integer(),
          events: non_neg_integer(),
          objects: non_neg_integer(),
          dropped: non_neg_integer(),
          mapping_digest: String.t()
        }

  @stimulus_start [:ash_a2a, :chicago, :stimulus, :start]
  @stimulus_stop [:ash_a2a, :chicago, :stimulus, :stop]

  @doc """
  Starts an observer. Options: `:run_id` (required), `:mappings` (list of
  `Mapping`), `:name`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts)
    end
  end

  @spec records(GenServer.server()) :: [record()]
  def records(observer), do: GenServer.call(observer, :records)

  @spec records_for(GenServer.server(), String.t()) :: [record()]
  def records_for(observer, falsifier_id),
    do: GenServer.call(observer, {:records_for, falsifier_id})

  @spec dropped(GenServer.server()) :: non_neg_integer()
  def dropped(observer), do: GenServer.call(observer, :dropped)

  @spec mapping_digest(GenServer.server()) :: String.t()
  def mapping_digest(observer), do: GenServer.call(observer, :mapping_digest)

  @doc """
  Writes `ocel.json` into `dir` (created if needed), fsyncs it, and returns
  its content digest. The artifact survives the observer and the producer
  process (§19).
  """
  @spec flush(GenServer.server(), Path.t()) :: {:ok, flush_result()} | {:error, term()}
  def flush(observer, dir), do: GenServer.call(observer, {:flush, dir}, 60_000)

  @spec stop(GenServer.server()) :: :ok
  def stop(observer), do: GenServer.stop(observer, :normal)

  # --- telemetry handler (runs in the EMITTING process) -------------------

  @doc false
  def handle_event(event, measurements, metadata, %{
        observer: observer,
        by_event: by_event,
        drops: drops
      }) do
    seq = System.unique_integer([:monotonic, :positive])
    time_us = System.system_time(:microsecond)
    measurements = if is_map(measurements), do: measurements, else: %{}
    metadata = if is_map(metadata), do: metadata, else: %{}

    records =
      case event do
        @stimulus_start ->
          [stimulus_record(event, "chicago.stimulus.start", measurements, metadata, seq, time_us)]

        @stimulus_stop ->
          [stimulus_record(event, "chicago.stimulus.stop", measurements, metadata, seq, time_us)]

        _ ->
          by_event
          |> Map.get(event, [])
          |> Enum.with_index()
          |> Enum.map(fn {mapping, ordinal} ->
            mapping
            |> mapped_record(event, measurements, metadata, seq, time_us)
            |> Map.put(:ordinal, ordinal)
          end)
      end

    for record <- records do
      try do
        GenServer.call(observer, {:record, record}, 5_000)
      catch
        _kind, _reason -> :counters.add(drops, 1, 1)
      end
    end

    :ok
  rescue
    _ -> :counters.add(drops, 1, 1)
  end

  defp mapped_record(%Mapping{} = mapping, event, measurements, metadata, seq, time_us) do
    {objects, object_error} = Mapping.objects(mapping, measurements, metadata)
    {attributes, attr_error} = Mapping.attributes(mapping, measurements, metadata)

    attributes =
      attributes
      |> maybe_put("chicago_mapping_error", object_error || attr_error)

    %{
      seq: seq,
      event: event,
      activity: mapping.activity,
      time_us: time_us,
      attributes: attributes,
      objects: objects,
      falsifier_id: nil,
      court_id: nil
    }
  end

  defp stimulus_record(event, activity, measurements, metadata, seq, time_us) do
    attributes =
      %{}
      |> maybe_put("outcome", Mapping.scalar(Map.get(metadata, :outcome)))
      |> maybe_put("duration_us", Mapping.scalar(Map.get(measurements, :duration_us)))

    %{
      seq: seq,
      event: event,
      activity: activity,
      time_us: time_us,
      attributes: attributes,
      objects: [],
      falsifier_id: Map.get(metadata, :falsifier_id),
      court_id: Map.get(metadata, :court_id),
      run_id: Map.get(metadata, :run_id)
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # --- GenServer -----------------------------------------------------------

  @impl true
  def init(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    mappings = Keyword.get(opts, :mappings, [])
    drops = :counters.new(1, [:write_concurrency])
    by_event = Enum.group_by(mappings, & &1.event)
    handler_id = {__MODULE__, run_id, make_ref()}
    events = Enum.uniq(Context.stimulus_events() ++ Map.keys(by_event))

    :ok =
      :telemetry.attach_many(handler_id, events, &__MODULE__.handle_event/4, %{
        observer: self(),
        by_event: by_event,
        drops: drops
      })

    {:ok,
     %{
       run_id: run_id,
       handler_id: handler_id,
       mapping_digest: Mapping.digest(mappings),
       drops: drops,
       active: nil,
       records: []
     }}
  end

  @impl true
  def handle_call({:record, %{activity: "chicago.stimulus.start"} = record}, _from, state) do
    if record[:run_id] == state.run_id do
      active = %{falsifier_id: record.falsifier_id, court_id: record.court_id}
      {:reply, :ok, %{state | active: active, records: [record | state.records]}}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call({:record, %{activity: "chicago.stimulus.stop"} = record}, _from, state) do
    if record[:run_id] == state.run_id do
      {:reply, :ok, %{state | active: nil, records: [record | state.records]}}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call({:record, record}, _from, state) do
    record =
      case state.active do
        nil -> record
        active -> %{record | falsifier_id: active.falsifier_id, court_id: active.court_id}
      end

    {:reply, :ok, %{state | records: [record | state.records]}}
  end

  def handle_call(:records, _from, state), do: {:reply, sorted(state.records), state}

  def handle_call({:records_for, id}, _from, state),
    do: {:reply, state.records |> Enum.filter(&(&1.falsifier_id == id)) |> sorted(), state}

  def handle_call(:dropped, _from, state), do: {:reply, :counters.get(state.drops, 1), state}
  def handle_call(:mapping_digest, _from, state), do: {:reply, state.mapping_digest, state}

  def handle_call({:flush, dir}, _from, state) do
    {:reply, write_artifact(state, dir), state}
  end

  @impl true
  def terminate(_reason, state) do
    :telemetry.detach(state.handler_id)
    :ok
  end

  defp sorted(records), do: Enum.sort_by(records, & &1.seq)

  defp write_artifact(state, dir) do
    records = sorted(state.records)
    dropped = :counters.get(state.drops, 1)
    log = build_log(records, state)
    json = Log.encode(log)
    path = Path.join(dir, "ocel.json")

    with :ok <- File.mkdir_p(dir),
         :ok <- durable_write(path, json) do
      {:ok,
       %{
         path: path,
         sha256: :crypto.hash(:sha256, json) |> Base.encode16(case: :lower),
         bytes: byte_size(json),
         events: length(records),
         objects: map_size(log.objects),
         dropped: dropped,
         mapping_digest: state.mapping_digest
       }}
    end
  rescue
    exception -> {:error, {:ocel_write_failed, Exception.message(exception)}}
  end

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

  defp build_log(records, state) do
    run_oid = oid("chicago_run", state.run_id)

    log =
      Log.new()
      |> Log.put_object("chicago_run", run_oid, %{
        "run_id" => state.run_id,
        "mapping_digest" => state.mapping_digest
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
        |> Map.put("telemetry_event", Enum.map_join(record.event, ".", &Atom.to_string/1))

      Log.add_event(log, %{
        id: event_id(record),
        type: record.activity,
        time: record.time_us,
        attributes: attributes,
        relationships: Enum.reverse([{run_oid, "observed_in"} | rels])
      })
    end)
  end

  # One telemetry event interpreted by N admitted mappings yields N records
  # sharing one `seq`; OCEL 2.0 event ids must stay unique (SA2A-OCEL-021).
  defp event_id(%{seq: seq} = record) do
    case Map.get(record, :ordinal, 0) do
      0 -> "e-#{seq}"
      ordinal -> "e-#{seq}.#{ordinal}"
    end
  end

  @doc "Globally-unique OCEL object id for `(type, id)`."
  @spec oid(String.t(), String.t()) :: String.t()
  def oid(type, id), do: type <> ":" <> id
end
