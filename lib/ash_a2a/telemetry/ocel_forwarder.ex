defmodule AshA2A.Telemetry.OcelForwarder do
  @moduledoc """
  Best-effort OCEL v2 egress for raw dispatch spans and committed AshA2A
  command receipts.

  Dispatch events preserve the existing low-level execution visibility.
  Receipt events add replay/identity/standing evidence from the canonical
  CommandBus without changing command behavior. Both are observational only.
  """

  require Logger

  @dispatch_handler_id {__MODULE__, :dispatch_stop}
  @receipt_handler_id {__MODULE__, :receipt_committed}
  @outboxed_handler_id {__MODULE__, :receipt_outboxed}
  @shed_counter_key {__MODULE__, :shed_counter}

  @spec attach!() :: :ok
  def attach! do
    :ok = attach(@dispatch_handler_id, [:ash_a2a, :dispatch, :stop])
    :ok = attach(@receipt_handler_id, [:ash_a2a, :receipt, :committed])
    :ok = attach(@outboxed_handler_id, [:ash_a2a, :receipt, :outboxed])
    :ok
  end

  @spec detach() :: :ok | {:error, :not_found}
  def detach do
    results = [
      :telemetry.detach(@dispatch_handler_id),
      :telemetry.detach(@receipt_handler_id),
      :telemetry.detach(@outboxed_handler_id)
    ]

    if :ok in results, do: :ok, else: {:error, :not_found}
  end

  @doc """
  Total OCEL events shed by the bounded fan-out (A2A-2602): events that
  exceeded the task supervisor's `max_children` ceiling and were dropped
  with an accounted shed (counter + `[:ash_a2a, :ocel, :shed]` telemetry),
  never silently.
  """
  @spec shed_count() :: non_neg_integer()
  def shed_count do
    case :persistent_term.get(@shed_counter_key, nil) do
      nil -> 0
      ref -> :counters.get(ref, 1)
    end
  end

  # `AshA2A.CommandBus.run/4` marks the calling process with
  # `:ash_a2a_ocel_command_bus_dispatch` for the duration of its internal
  # `AshA2A.Dispatcher.dispatch/5` call (see that module's
  # `dispatch_with_ocel_correlation/4`). When present, this dispatch-stop
  # event did NOT originate from a standalone direct-dispatch caller -- it is
  # the internal span inside a CommandBus-routed command that will also emit
  # its own `[:ash_a2a, :receipt, :committed]` event moments later. Stashing
  # `{measurements, metadata}` here (instead of posting immediately) and
  # merging them into that single receipt event below is what eliminates the
  # duplicate OCEL v2 POST for one logical CommandBus-routed dispatch, while
  # a direct `AshA2A.Dispatcher.dispatch/5` call (no marker present) keeps
  # posting immediately exactly as before.
  @doc false
  def handle_event([:ash_a2a, :dispatch, :stop], measurements, metadata, _config) do
    if Process.get(:ash_a2a_ocel_command_bus_dispatch) do
      Process.put(:ash_a2a_ocel_pending_dispatch, {measurements, metadata})
      :ok
    else
      case ingest_url() do
        nil -> :ok
        url -> async_post_event(url, build_dispatch_event(measurements, metadata))
      end
    end
  end

  def handle_event(
       [:ash_a2a, :receipt, :committed],
       _measurements,
       %{receipt: %AshA2A.Receipt{} = receipt},
       _config
     ) do
    case ingest_url() do
      nil -> :ok
      url -> async_post_event(url, receipt_event(receipt))
    end
  end

  # A2A-2601: a receipt whose primary store commit is pending (the
  # consequence HAPPENED, the receipt is durably outboxed) still forwards
  # its OCEL evidence -- the event carries the same receipt metadata the
  # committed event does. The later outbox reconciliation intentionally
  # emits NO `:committed` telemetry, so this outboxed event is the ONE
  # OCEL event for such a command, not a duplicate.
  def handle_event(
        [:ash_a2a, :receipt, :outboxed],
        _measurements,
        %{receipt: %AshA2A.Receipt{} = receipt},
        _config
      ) do
    case ingest_url() do
      nil -> :ok
      url -> async_post_event(url, receipt_event(receipt))
    end
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  defp attach(handler_id, event) do
    case :telemetry.attach(handler_id, event, &__MODULE__.handle_event/4, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  defp ingest_url, do: Application.get_env(:ash_a2a, :ocel_ingest_url)

  # Offloads the actual HTTP POST onto a supervised `Task` so a stalled or
  # slow OCEL ingest endpoint can never block the calling process. `:telemetry`
  # handlers execute synchronously, in-process, with no spawn
  # (`telemetry.erl`'s `do_execute/4`) -- and for every real AshA2A dispatch
  # that calling process is the single-mailbox `A2A.Agent` GenServer that also
  # serves the inbound HTTP request for that agent (`agent.ex`'s "one mailbox"
  # disclosure). `handle_event/4`'s return value is already discarded by
  # `:telemetry` itself in every branch, so fire-and-forget here changes no
  # observable behavior on the success path -- only removes the worst-case
  # blocking window. This must never wrap the `Process.put`/`Process.delete`
  # correlation-id bookkeeping in `handle_event/4` itself -- that logic is
  # required to run synchronously, in the calling process, per
  # `command_bus.ex`'s documented invariant (the process-dictionary flag is
  # only safe because `:telemetry.span/3` executes synchronously in the same
  # process) -- only the network call below is deferred.
  #
  # A2A-2602: the fan-out is BOUNDED. The supervisor is started with
  # `max_children` (`AshA2A.Application`), and a start beyond that ceiling
  # returns `{:error, :max_children}` -- accounted here as an explicit,
  # counted shed (see `shed_count/0`) instead of silently spawning one
  # process per event. The supervisor name is resolved through
  # `task_supervisor/0` so a host (or test) can substitute its own bounded
  # supervisor instance without touching this module.
  defp async_post_event(url, event) do
    case Task.Supervisor.start_child(task_supervisor(), fn ->
           post_event(url, event)
         end) do
      {:ok, _pid} ->
        :ok

      {:error, :max_children} ->
        shed_event(url)
        :ok

      {:error, _other_reason} ->
        :ok
    end
  end

  defp task_supervisor do
    Application.get_env(:ash_a2a, :ocel_task_supervisor, AshA2A.Telemetry.TaskSupervisor)
  end

  # The accounted drop: a `:counters`-backed total (readable via
  # `shed_count/0`) plus one `[:ash_a2a, :ocel, :shed]` telemetry event per
  # shed, so observability consumers can alert on OCEL evidence loss under
  # burst rather than discovering it silently. Deliberately no per-event
  # `Logger` call: a burst that trips the ceiling must not turn into a log
  # flood of its own.
  defp shed_event(url) do
    :counters.add(shed_counter(), 1, 1)
    :telemetry.execute([:ash_a2a, :ocel, :shed], %{}, %{url: url})
    :ok
  end

  defp shed_counter do
    case :persistent_term.get(@shed_counter_key, nil) do
      nil ->
        ref = :counters.new(1, [])
        :persistent_term.put(@shed_counter_key, ref)
        ref

      ref ->
        ref
    end
  end

  defp post_event(url, event) do
    Req.post(url <> "/ocel/events",
      json: %{"events" => [event]},
      receive_timeout: receive_timeout_ms()
    )
    |> case do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning(
          "AshA2A.Telemetry.OcelForwarder: ingest at #{url} returned non-2xx status #{status}: #{inspect(body)}"
        )

        :ok

      {:error, reason} ->
        Logger.warning(
          "AshA2A.Telemetry.OcelForwarder: failed to forward OCEL event to #{url}: #{inspect(reason)}"
        )

        :ok
    end
  rescue
    error ->
      Logger.warning(
        "AshA2A.Telemetry.OcelForwarder: unexpected error forwarding OCEL event: #{inspect(error)}"
      )

      :ok
  end

  # Builds the single OCEL v2 event posted for a `[:ash_a2a, :receipt,
  # :committed]` event. When this receipt was reached via a CommandBus-routed
  # dispatch, `handle_event/4`'s dispatch-stop clause above left the raw
  # dispatch span's `{measurements, metadata}` behind under
  # `:ash_a2a_ocel_pending_dispatch` -- read and cleared here (never left
  # stale across calls) and merged in, via the same real `dispatch_attributes/2`
  # and `relationships/1` helpers a direct dispatch event already uses, so no
  # evidence from the raw dispatch span (duration, reply_type, object_id
  # relationships) is lost -- only the duplicate POST is eliminated. A direct
  # `AshA2A.Dispatcher.dispatch/5` call never sets that key, so
  # `Process.delete/1` returns `nil` and the receipt-only event is emitted
  # unchanged.
  defp receipt_event(receipt) do
    event = AshA2A.SemanticProjection.ocel_event(receipt)

    case Process.delete(:ash_a2a_ocel_pending_dispatch) do
      {measurements, metadata} ->
        event
        |> Map.update!("attributes", &Map.merge(&1, dispatch_attributes(measurements, metadata)))
        |> Map.put("relationships", relationships(metadata))

      nil ->
        event
    end
  end

  defp build_dispatch_event(measurements, metadata) do
    %{
      "event_id" => Ash.UUIDv7.generate(),
      "event_type" => event_type(metadata),
      "event_time" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "attributes" => dispatch_attributes(measurements, metadata),
      "relationships" => relationships(metadata)
    }
  end

  # Real E2O relationship, present exactly when `AshA2A.Dispatcher` resolved
  # a real object identity for this dispatch (`dispatcher.ex`'s `object_id/2`
  # -- a persisted Ash record's own primary key, or, for a generic `:action`
  # skill with no data-layer record at all, a real `plan_name` argument
  # naming a specific stateful instance). `[]` (never a fabricated id) when
  # the dispatch had no real object to relate to (e.g. a pure stateless echo
  # skill like `:run_phase`). Field name matches beam4pm's real
  # `BeamPM.OcelIngest.Router` wire contract exactly (`lib/beam4pm_ocel_ingest.ex`
  # `decode_relationships/1`: `"qualifier"` / `"object_id"`, snake_case --
  # not `"objectId"`).
  defp relationships(%{object_id: object_id}) when is_binary(object_id) and object_id != "" do
    [%{"qualifier" => "acted_on", "object_id" => object_id}]
  end

  defp relationships(_metadata), do: []

  defp event_type(%{resource_or_domain: resource, skill_name: skill}) do
    short_name =
      if Ash.Resource.Info.resource?(resource) do
        Ash.Resource.Info.short_name(resource)
      else
        inspect(resource)
      end

    "ash_a2a.dispatch.#{short_name}.#{skill}"
  end

  defp dispatch_attributes(measurements, metadata) do
    base = %{
      "skill_name" => to_string(Map.get(metadata, :skill_name)),
      "resource_or_domain" => inspect(Map.get(metadata, :resource_or_domain)),
      "reply_type" => metadata |> Map.get(:reply_type) |> to_string_or_nil(),
      "duration_native" => measurements |> Map.get(:duration) |> to_string_or_nil()
    }

    case Map.get(metadata, :stage) do
      nil ->
        base

      stage ->
        base
        |> Map.put("stage", to_string(stage))
        |> Map.put("error", inspect(Map.get(metadata, :error)))
    end
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)

  defp receive_timeout_ms, do: Application.get_env(:ash_a2a, :ocel_ingest_timeout_ms, 2_000)
end
