# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Trace do
  @moduledoc """
  TRACE-compliant trace export for A2A task sagas.

  Exports a complete task saga (dispatch -> authority -> actuation -> receipt)
  as an OpenTelemetry-aligned trace document: spans with W3C-shaped
  traceId/spanId/parentSpanId links, attributes drawn from the A2A envelope
  and dispatcher/command-bus telemetry, and span events carrying the
  authority/command-bus/receipt boundaries plus the task's
  AshA2A.A2ATransport.TaskEvents wire log. Exportable both as this document
  and as OTLP/JSON (TracesData), matching the A2A spec's observability
  direction ("use OpenTelemetry to propagate trace context, including trace
  IDs and span IDs"; "log details ... including taskId, sessionId,
  correlation IDs, and trace context" -- A2A enterprise-ready guidance, the
  TRACE ground truth vendored in ggen-marketplace/vendors/a2a).

  The saga is recorded observationally by AshA2A.Trace.Recorder from real
  telemetry; export is a pure fold over those records plus the task's wire
  events, so the same recorded saga always folds to the same structure.

  ## Identity determinism

  traceId and every spanId are derived deterministically from the task id
  (SHA-256 over a namespaced string), so the same saga shape always exports
  the same trace structure and identity -- only timestamps (and record
  contents driven by real behavior) differ between sagas of different tasks.
  """

  alias AshA2A.A2ATransport
  alias AshA2A.A2ATransport.TaskEvents
  alias AshA2A.Trace.Recorder

  @typedoc "Export formats: the trace document or OTLP/JSON TracesData."
  @type format :: :trace | :otlp

  @scope_name "ash_a2a.trace"

  @doc """
  Exports the recorded saga of `task_id` on `transport`.

  ## Options

    * `:format` -- `:trace` (default, the trace document) or `:otlp`
      (OTLP/JSON TracesData).
    * `:agent` -- the agent process holding the task; when given, the task
      span carries the live A2A envelope attributes (task id, context id,
      wire state, owner principal) read from the real task record.

  Returns `{:ok, document}` or `{:error, :not_found}` when nothing is recorded
  for the task (no saga spans and no wire events).
  """
  @spec export(atom(), String.t(), keyword()) :: {:ok, map()} | {:error, :not_found}
  def export(transport, task_id, opts \\ []) when is_atom(transport) and is_binary(task_id) do
    Recorder.ensure()

    records = Recorder.records(task_id)
    backlog = wire_events_log(transport, task_id)

    if records == [] and backlog == [] do
      {:error, :not_found}
    else
      trace_id = trace_id(task_id)

      spans =
        build_spans(task_id, trace_id, records, backlog, envelope(opts[:agent], task_id))

      case Keyword.get(opts, :format, :trace) do
        :trace ->
          {:ok, trace_document(task_id, trace_id, spans)}

        :otlp ->
          {:ok, otlp_document(Enum.map(spans, &otlp_span/1))}

        other ->
          raise ArgumentError, "unknown AshA2A.Trace format #{inspect(other)}"
      end
    end
  end

  @doc "The deterministic 32-hex trace id for `task_id`."
  @spec trace_id(String.t()) :: String.t()
  def trace_id(task_id) do
    :crypto.hash(:sha256, "a2a:trace:" <> task_id)
    |> binary_part(0, 16)
    |> Base.encode16(case: :lower)
  end

  @doc "The deterministic 16-hex span identity for `task_id`'s span `span_key`."
  @spec span_id(String.t(), Recorder.span_key()) :: String.t()
  def span_id(task_id, span_key) do
    :crypto.hash(:sha256, "a2a:span:" <> task_id <> ":" <> span_key)
    |> binary_part(0, 8)
    |> Base.encode16(case: :lower)
  end

  # -- span folding -----------------------------------------------------------
  # One pass over the records in sequence order builds the spans (in open
  # order), closes them (a span never closed by telemetry -- a crashed worker
  # -- is closed at the last recorded timestamp), and collects span events.

  defp build_spans(task_id, trace_id, records, backlog, envelope) do
    acc = fold_records(task_id, trace_id, records)

    spans =
      Map.new(acc.spans, fn
        {key, %{"endTimeUnixNano" => nil} = span} ->
          {key, Map.put(span, "endTimeUnixNano", Integer.to_string(acc.last_sys || 0))}

        closed ->
          closed
      end)

    acc.order
    |> Enum.reverse()
    |> Enum.map(fn key ->
      span = Map.fetch!(spans, key)
      recorded = acc.events |> Map.get(key, []) |> Enum.reverse()

      if key == "task" do
        span
        |> Map.update!("attributes", &Map.merge(&1, envelope))
        |> Map.put("events", wire_events(backlog) ++ recorded)
      else
        Map.put(span, "events", recorded)
      end
    end)
  end

  defp fold_records(task_id, trace_id, records) do
    Enum.reduce(records, %{spans: %{}, order: [], events: %{}, last_sys: nil}, fn
      {_seq, {:open, key, name, parent_key, _mono, sys, attrs}}, acc ->
        span = %{
          "traceId" => trace_id,
          "spanId" => span_id(task_id, key),
          "parentSpanId" => if(parent_key, do: span_id(task_id, parent_key), else: ""),
          "name" => name,
          "kind" => span_kind(name),
          "startTimeUnixNano" => Integer.to_string(sys),
          "endTimeUnixNano" => nil,
          "attributes" => attrs || %{},
          "status" => "STATUS_CODE_UNSET",
          "events" => []
        }

        acc
        |> Map.put(:spans, Map.put(acc.spans, key, span))
        |> Map.put(:order, [key | acc.order])

      {_seq, {:close, key, _mono, sys, extra_attrs, status}}, acc ->
        case acc.spans do
          %{^key => span} ->
            closed =
              span
              |> Map.put("endTimeUnixNano", Integer.to_string(sys))
              |> Map.update!("attributes", &Map.merge(&1, extra_attrs || %{}))
              |> Map.put(
                "status",
                if(status == :error, do: "STATUS_CODE_ERROR", else: "STATUS_CODE_OK")
              )

            acc
            |> Map.put(:spans, Map.put(acc.spans, key, closed))
            |> Map.put(:last_sys, sys)

          _ ->
            Map.put(acc, :last_sys, sys)
        end

      {_seq, {:event, key, name, _mono, sys, attrs}}, acc ->
        event = %{
          "name" => name,
          "timeUnixNano" => Integer.to_string(sys),
          "attributes" => attrs || %{}
        }

        # dual-safe Map.update: absent key stores the default verbatim (no fun),
        # immune to the documented/actual Map.update/4 semantics divergence.
        case Map.fetch(acc, :events) do
          :error ->
            Map.put(acc, :events, %{key => [event]})

          {:ok, events} ->
            events =
              case Map.fetch(events, key) do
                :error -> Map.put(events, key, [event])
                {:ok, prior} -> Map.put(events, key, [event | prior])
              end

            Map.put(acc, :events, events)
        end
    end)
  end

  # TaskEvents backlog (`{seq, kind, payload, final?}`) as task-span events;
  # the wire log carries no per-event timestamp, so these events carry their
  # sequence attributes only -- order-preserving and replay-deterministic.
  defp wire_events(backlog) do
    for {seq, kind, _payload, final?} <- backlog do
      %{
        "name" => kind,
        "attributes" => %{
          "a2a.event.seq" => seq,
          "a2a.event.final" => final?
        }
      }
    end
  end

  defp span_kind("a2a.task"), do: "SPAN_KIND_SERVER"
  defp span_kind(_name), do: "SPAN_KIND_INTERNAL"

  # -- envelope -----------------------------------------------------------------

  defp wire_events_log(transport, task_id) do
    if A2ATransport.running?(transport) do
      TaskEvents.backlog(transport, task_id)
    else
      []
    end
  rescue
    _ -> []
  end

  defp envelope(nil, _task_id), do: %{}

  defp envelope(agent, task_id) do
    try do
      case GenServer.whereis(agent) do
        nil ->
          %{}

        _pid ->
          case GenServer.call(agent, {:get_task, task_id}) do
            {:ok, task} -> envelope_attrs(task)
            _ -> %{}
          end
      end
    catch
      :exit, _ -> %{}
    end
  end

  defp envelope_attrs(task) do
    wire =
      try do
        AshA2A.Protocol.JSON.encode!(task)
      rescue
        _ -> %{}
      end

    %{}
    |> maybe_put("a2a.task.id", wire["id"])
    |> maybe_put("a2a.task.context_id", wire["contextId"])
    |> maybe_put("a2a.task.state", get_in(wire, ["status", "state"]))
    |> maybe_put("a2a.principal", owner(task))
  end

  defp owner(%{metadata: %{"ash_a2a.owner" => owner}}) when is_binary(owner), do: owner
  defp owner(_task), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # -- documents -----------------------------------------------------------------

  defp trace_document(task_id, trace_id, spans) do
    %{
      "traceId" => trace_id,
      "taskId" => task_id,
      "spans" => spans
    }
  end

  defp otlp_document(spans) do
    %{
      "resourceSpans" => [
        %{
          "resource" => %{
            "attributes" =>
              otlp_attributes(%{
                "service.name" => "ash_a2a",
                "service.namespace" => "a2a"
              })
          },
          "scopeSpans" => [
            %{"scope" => %{"name" => @scope_name}, "spans" => spans}
          ]
        }
      ]
    }
  end

  defp otlp_span(span) do
    span
    |> Map.update!("attributes", &otlp_attributes/1)
    |> Map.update!("events", fn events ->
      Enum.map(events, fn event -> Map.update!(event, "attributes", &otlp_attributes/1) end)
    end)
  end

  defp otlp_attributes(map) do
    for {key, value} <- map, not is_nil(value) do
      value =
        cond do
          is_boolean(value) -> %{"boolValue" => value}
          is_integer(value) -> %{"intValue" => value}
          true -> %{"stringValue" => to_string(value)}
        end

      %{"key" => key, "value" => value}
    end
  end
end
