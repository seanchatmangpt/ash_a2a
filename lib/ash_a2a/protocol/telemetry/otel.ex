defmodule AshA2A.Protocol.Telemetry.OTel do
  @moduledoc """
  Optional bridge from `:telemetry` span events to OpenTelemetry spans.

  `attach/0` is a no-op returning `{:error, :opentelemetry_not_loaded}` unless
  `OpenTelemetry.Tracer` is loaded. All OTel calls go through `apply/3`, so
  this module compiles with `opentelemetry_api` absent.
  """

  @prefixes [
    [:a2a, :agent, :call],
    [:a2a, :agent, :message],
    [:a2a, :agent, :cancel],
    [:a2a, :push_notification, :delivery]
  ]
  @handler_id "ash-a2a-otel"

  @doc "True when the OpenTelemetry API is available."
  def available?, do: Code.ensure_loaded?(OpenTelemetry.Tracer)

  @doc "Attach handlers. No-op when the OTel API is absent."
  def attach do
    if available?() do
      events =
        for p <- @prefixes, suffix <- [:start, :stop, :exception], do: p ++ [suffix]

      :telemetry.detach(@handler_id)
      :telemetry.attach_many(@handler_id, events, &__MODULE__.handle_event/4, nil)
    else
      {:error, :opentelemetry_not_loaded}
    end
  end

  def detach, do: :telemetry.detach(@handler_id)

  @doc """
  Set the remote parent from W3C headers using the configured text-map
  propagator. No-op when OTel is absent.
  """
  def attach_remote_context(headers) when is_list(headers) do
    if available?() and Code.ensure_loaded?(:otel_propagator_text_map) do
      apply(:otel_propagator_text_map, :extract, [headers])
    else
      :ok
    end
  end

  @doc false
  def handle_event(event, _measurements, metadata, _config) do
    {prefix, kind} = Enum.split(event, -1)
    key = {__MODULE__, prefix}

    case kind do
      [:start] -> start_span(key, prefix, metadata)
      [:stop] -> end_span(key, metadata, nil)
      [:exception] -> end_span(key, metadata, Map.get(metadata, :reason))
    end
  rescue
    _ -> :ok
  end

  defp start_span(key, prefix, _metadata) do
    tracer = apply(:opentelemetry, :get_application_tracer, [__MODULE__])
    name = prefix |> Enum.map_join(".", &Atom.to_string/1)
    span = apply(:otel_tracer, :start_span, [tracer, name, %{}])
    prev = apply(:otel_tracer, :current_span_ctx, [])
    apply(:otel_tracer, :set_current_span, [span])
    Process.put(key, {span, prev})
    :ok
  end

  defp end_span(key, _metadata, reason) do
    case Process.delete(key) do
      {span, prev} ->
        if reason do
          apply(:otel_span, :set_status, [
            span,
            apply(:opentelemetry, :status, [:error, inspect(reason)])
          ])
        end

        apply(:otel_span, :end_span, [span])
        apply(:otel_tracer, :set_current_span, [prev])
        :ok

      nil ->
        :ok
    end
  end
end
