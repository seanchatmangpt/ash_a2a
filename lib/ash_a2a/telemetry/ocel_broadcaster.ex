# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Telemetry.OcelBroadcaster do
  @moduledoc """
  The enterprise OCEL broadcaster child (ARD v26.10.4 §2, gate key `:siem`,
  `docs/jira/v26.10.4/ARD.md` line 35): a telemetry-handler GenServer that
  converts the repo's own telemetry events into IEEE OCEL v2 event maps
  (the exact shape `AshA2A.Telemetry.OcelForwarder` and
  `AshA2A.SemanticProjection.ocel_event/1` pin — consumed read-only),
  buffers them in a bounded queue, and flushes them to configured SIEM
  `deliver/3` sinks via `AshA2A.Telemetry.SIEM.deliver/3`.

  ## Events converted

  The same four `:telemetry` events `AshA2A.Telemetry.OcelForwarder`
  forwards: `[:ash_a2a, :dispatch, :stop]`,
  `[:ash_a2a, :dispatch, :exception]`, `[:ash_a2a, :receipt, :committed]`
  and `[:ash_a2a, :receipt, :outboxed]`. Dispatch spans become
  `"ash_a2a.dispatch.<resource>.<skill>"` event types (with the
  `.exception` suffix on the exception event, a redacted error-code kind —
  never a stacktrace); receipt events are projected by the real
  `AshA2A.SemanticProjection.ocel_event/1`.

  ## Supervisor integration

  `AshA2A.Enterprise.Supervisor` starts this module when
  `config :ash_a2a, :siem` is set, passing the gate value itself as keyword
  opts. Accepted opts (all optional):

    * `:name` — GenServer registered name (default `__MODULE__`).
    * `:endpoints` — SIEM sink specs, one per configured endpoint. Each spec
      is either a keyword list whose `:platform` key names the
      `AshA2A.Telemetry.SIEM` platform (or adapter module) and whose
      remaining keys are that adapter's `deliver/3` config (e.g.
      `[platform: :splunk_hec, endpoint: "https://hec.example.com", token: "…"]`),
      or a bare endpoint URL string, which uses the `:platform` opt as its
      platform (default `:splunk_hec`). The supervisor value shape
      `[endpoints: [String.t()]]` is the bare-URL form.
    * `:platform` — platform for bare-URL endpoint specs (default
      `:splunk_hec`).
    * `:siem_opts` — keyword merged into every sink's `deliver/3` config at
      flush time (`:batch_size`, `:max_retries`, `:backoff_base_ms`,
      `:max_backoff_ms`, `:transport_opts`, ...).
    * `:max_buffer` — bounded-queue size (default `10_000`, minimum 1).
    * `:flush_interval_ms` — periodic flush interval (default `5_000`;
      `false` disables the timer; `flush/1` always works).

  ## Overflow: drop-oldest, never backpressure

  The telemetry handler runs in the emitting process and only casts; the
  buffer is a `:queue` bounded by `:max_buffer`. When full, the OLDEST event
  is dropped to admit the newest, the drop is counted (`drop_count/1`), and
  one `[:ash_a2a, :ocel_broadcaster, :dropped]` telemetry event is emitted
  per overflow. Dispatch is never blocked.

  ## Config-gated idle

  Unconfigured (`:endpoints` absent/empty), the broadcaster starts, attaches
  its handlers, and idles: events are cast to it and discarded, nothing is
  buffered, no timer runs, no HTTP leaves. Flush delivery failures are typed
  (`{:error, {:siem_delivery_failed, platform, reason}}` and friends from
  `deliver/3`), counted, emitted as
  `[:ash_a2a, :ocel_broadcaster, :flush_failed]`, and the events are
  re-buffered (same drop-oldest bound) for the next flush — the broadcaster
  never crashes and never blocks the dispatch path it observes.
  """

  use GenServer

  require Logger

  @typedoc "Accepted broadcaster options (module doc)."
  @type opts :: [{atom(), term()}]

  @default_platform :splunk_hec
  @default_max_buffer 10_000
  @default_flush_interval_ms 5_000

  @subscribed_events [
    {[:ash_a2a, :dispatch, :stop], :dispatch_stop},
    {[:ash_a2a, :dispatch, :exception], :dispatch_exception},
    {[:ash_a2a, :receipt, :committed], :receipt_committed},
    {[:ash_a2a, :receipt, :outboxed], :receipt_outboxed}
  ]

  @type kind :: :dispatch_stop | :dispatch_exception | :receipt_committed | :receipt_outboxed

  # -- public API ---------------------------------------------------------------

  @doc "Starts the broadcaster; options in the module doc."
  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @doc "The four telemetry events this module subscribes to, with handler kinds."
  @spec subscribed_events() :: [{[atom()], kind()}]
  def subscribed_events, do: @subscribed_events

  @doc """
  Attaches the four telemetry handlers under `name`-keyed handler ids.
  Called by `init/1`; public so a court can re-attach after a `:telemetry`
  sweep.
  """
  @spec attach!(atom()) :: :ok
  def attach!(name \\ __MODULE__) do
    Enum.each(@subscribed_events, fn {event, kind} ->
      case :telemetry.attach({name, kind}, event, &__MODULE__.handle_event/4, {name, kind}) do
        :ok -> :ok
        {:error, :already_exists} -> :ok
      end
    end)

    :ok
  end

  @doc "Detaches the broadcaster's telemetry handlers."
  @spec detach(atom()) :: :ok | {:error, :not_found}
  def detach(name \\ __MODULE__) do
    results = Enum.map(@subscribed_events, fn {_event, kind} -> :telemetry.detach({name, kind}) end)

    if :ok in results, do: :ok, else: {:error, :not_found}
  end

  @doc "Number of OCEL events currently buffered."
  @spec buffer_count(atom()) :: non_neg_integer()
  def buffer_count(name \\ __MODULE__), do: GenServer.call(name, :buffer_count)

  @doc "Total OCEL events dropped by the drop-oldest overflow policy."
  @spec drop_count(atom()) :: non_neg_integer()
  def drop_count(name \\ __MODULE__), do: GenServer.call(name, :drop_count)

  @doc "Whether any SIEM sink is configured (false = started-but-idle)."
  @spec configured?(atom()) :: boolean()
  def configured?(name \\ __MODULE__), do: GenServer.call(name, :configured?)

  @doc """
  Flushes the buffer to every configured sink now (synchronous). Returns
  `:ok` regardless of per-sink delivery outcomes — failures are typed,
  counted, emitted as `[:ash_a2a, :ocel_broadcaster, :flush_failed]`, and
  the events are re-buffered for the next flush.
  """
  @spec flush(atom()) :: :ok
  def flush(name \\ __MODULE__), do: GenServer.call(name, :flush)

  # -- telemetry handler (runs in the EMITTING process) -------------------------

  @doc false
  def handle_event(_event, measurements, metadata, {name, kind}) do
    # Cheap and non-raising: conversion happens inside the broadcaster, never
    # in the emitter. `GenServer.cast/2` never backpressures the caller.
    GenServer.cast(name, {:event, kind, measurements, metadata})
  end

  # -- GenServer -----------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)

    state = %{
      name: name,
      sinks: resolve_sinks(opts),
      siem_opts: Keyword.get(opts, :siem_opts, []),
      max_buffer: max(1, Keyword.get(opts, :max_buffer, @default_max_buffer)),
      flush_interval_ms: Keyword.get(opts, :flush_interval_ms, @default_flush_interval_ms),
      queue: :queue.new(),
      size: 0,
      drops: 0
    }

    :ok = attach!(name)

    if state.sinks != [] and is_integer(state.flush_interval_ms) do
      {:ok, schedule(state)}
    else
      {:ok, state}
    end
  end

  @impl GenServer
  def terminate(_reason, %{name: name}), do: detach(name)

  @impl GenServer
  def handle_call(:buffer_count, _from, state), do: {:reply, state.size, state}
  def handle_call(:drop_count, _from, state), do: {:reply, state.drops, state}
  def handle_call(:configured?, _from, state), do: {:reply, state.sinks != [], state}

  def handle_call(:flush, _from, %{sinks: []} = state), do: {:reply, :ok, state}

  def handle_call(:flush, _from, state) do
    {events, state} = drain(state)
    {:reply, :ok, deliver(events, state)}
  end

  @impl GenServer
  # Config-gated idle: with no sink, events are discarded before conversion —
  # nothing is buffered, no drop telemetry, zero side effects.
  def handle_cast({:event, _kind, _measurements, _metadata}, %{sinks: []} = state) do
    {:noreply, state}
  end

  def handle_cast({:event, kind, measurements, metadata}, state) do
    case to_ocel_event(kind, measurements, metadata) do
      nil -> {:noreply, state}
      event -> {:noreply, buffer(event, state)}
    end
  end

  def handle_cast(_other, state), do: {:noreply, state}

  @impl GenServer
  def handle_info(:flush, %{sinks: []} = state), do: {:noreply, state}

  def handle_info(:flush, state) do
    {events, state} = drain(state)
    {:noreply, state |> deliver(events) |> schedule()}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # -- buffering (drop-oldest, never backpressure) ---------------------------------

  defp buffer(event, %{size: size, max_buffer: max_buffer} = state) when size >= max_buffer do
    # Drop-oldest: one out, one in; the count stays at `max_buffer`.
    {{:value, _dropped}, queue} = :queue.out(state.queue)
    state = %{state | queue: :queue.in(event, queue), drops: state.drops + 1}
    emit_dropped(state)
    state
  end

  defp buffer(event, state) do
    %{state | queue: :queue.in(event, state.queue), size: state.size + 1}
  end

  defp drain(%{queue: queue} = state) do
    events = :queue.to_list(queue)
    {events, %{state | queue: :queue.new(), size: 0}}
  end

  defp emit_dropped(%{name: name, drops: total}) do
    :telemetry.execute([:ash_a2a, :ocel_broadcaster, :dropped], %{count: 1}, %{
      broadcaster: name,
      dropped_total: total
    })
  end

  # -- delivery ----------------------------------------------------------------------

  defp deliver(_events, %{sinks: []} = state), do: state
  defp deliver([], state), do: state

  defp deliver(events, %{sinks: sinks} = state) do
    Enum.reduce(sinks, state, fn {platform, sink_config}, state ->
      config = Keyword.merge(sink_config, state.siem_opts)

      case AshA2A.Telemetry.SIEM.deliver(platform, events, config) do
        {:ok, _report} ->
          state

        {:error, _typed} = failure ->
          Logger.warning(
            "AshA2A.Telemetry.OcelBroadcaster: SIEM flush to #{inspect(platform)} failed " <>
              "(#{inspect(failure)}); #{length(events)} event(s) re-buffered drop-oldest bounded"
          )

          emit_flush_failed(failure, state)
          rebuffer(events, state)
      end
    end)
  end

  defp emit_flush_failed(failure, %{name: name}) do
    :telemetry.execute([:ash_a2a, :ocel_broadcaster, :flush_failed], %{count: 1}, %{
      broadcaster: name,
      reason: failure
    })
  end

  # Re-queue the unflushed events at the FRONT (in order) so the next flush
  # drains them first; bounded by the same drop-oldest policy.
  defp rebuffer(events, state) do
    Enum.reduce(events, state, &buffer/2)
  end

  defp schedule(%{flush_interval_ms: interval} = state) when is_integer(interval) do
    Process.send_after(self(), :flush, interval)
    state
  end

  defp schedule(state), do: state

  # -- OCEL v2 conversion (shapes pinned read-only by the forwarder/projection courts)

  defp to_ocel_event(_kind, _measurements, %AshA2A.Receipt{} = receipt) do
    AshA2A.SemanticProjection.ocel_event(receipt)
  end

  defp to_ocel_event(:dispatch_stop, measurements, metadata) when is_map(measurements) do
    dispatch_event(metadata, measurements, :stop)
  end

  defp to_ocel_event(:dispatch_exception, measurements, metadata) when is_map(measurements) do
    dispatch_event(metadata, measurements, :exception)
  end

  defp to_ocel_event(_kind, _measurements, _metadata), do: nil

  defp dispatch_event(metadata, measurements, kind) do
    %{
      "event_id" => Ash.UUIDv7.generate(),
      "event_type" => dispatch_event_type(metadata, kind),
      "event_time" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "attributes" => dispatch_attributes(measurements, metadata, kind),
      "relationships" => relationships(metadata)
    }
  end

  defp dispatch_event_type(metadata, :exception) do
    dispatch_event_type(metadata, :stop) <> ".exception"
  end

  defp dispatch_event_type(metadata, :stop) do
    resource = Map.get(metadata, :resource_or_domain)
    skill = Map.get(metadata, :skill_name)

    short_name =
      if is_atom(resource) and Ash.Resource.Info.resource?(resource) do
        Ash.Resource.Info.short_name(resource)
      else
        inspect(resource)
      end

    "ash_a2a.dispatch.#{short_name}.#{skill}"
  end

  defp dispatch_attributes(measurements, metadata, :stop) do
    %{
      "skill_name" => to_string(Map.get(metadata, :skill_name)),
      "resource_or_domain" => inspect(Map.get(metadata, :resource_or_domain)),
      "reply_type" => to_string_or_nil(Map.get(metadata, :reply_type)),
      "duration_native" => to_string_or_nil(Map.get(measurements, :duration))
    }
  end

  defp dispatch_attributes(measurements, metadata, :exception) do
    Map.merge(dispatch_attributes(measurements, metadata, :stop), %{
      "kind" => to_string_or_nil(Map.get(metadata, :kind)),
      "error_code" =>
        case AshA2A.Telemetry.Redact.error_summary(Map.get(metadata, :reason)) do
          %{kind: kind} -> to_string(kind)
          _ -> nil
        end
    })
  end

  defp relationships(%{object_id: object_id}) when is_binary(object_id) and object_id != "" do
    [%{"qualifier" => "acted_on", "object_id" => object_id}]
  end

  defp relationships(_metadata), do: []

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)

  # -- sink resolution -----------------------------------------------------------------

  defp resolve_sinks(opts) do
    endpoints = opts |> Keyword.get(:endpoints, []) |> List.wrap()
    default_platform = Keyword.get(opts, :platform, @default_platform)

    Enum.flat_map(endpoints, fn
      {platform, config} when is_atom(platform) and is_list(config) ->
        [{platform, config}]

      spec when is_list(spec) and spec != [] ->
        case Keyword.fetch(spec, :platform) do
          {:ok, platform} -> [{platform, Keyword.delete(spec, :platform)}]
          :error -> unrecognised_sink(spec)
        end

      endpoint when is_binary(endpoint) and endpoint != "" ->
        [{default_platform, [endpoint: endpoint]}]

      other ->
        unrecognised_sink(other)
    end)
  end

  defp unrecognised_sink(spec) do
    Logger.warning(
      "AshA2A.Telemetry.OcelBroadcaster: ignoring unrecognised SIEM sink spec #{inspect(spec)}"
    )

    []
  end
end
