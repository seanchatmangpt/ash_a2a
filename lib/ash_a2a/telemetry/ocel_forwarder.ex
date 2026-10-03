defmodule AshA2A.Telemetry.OcelForwarder do
  @moduledoc """
  Best-effort OCEL v2 egress for raw dispatch spans and committed AshA2A
  command receipts.

  Dispatch events preserve the existing low-level execution visibility.
  Receipt events add replay/identity/standing evidence from the canonical
  CommandBus without changing command behavior. Both are observational only.

  ## Forwarded events

  Four `:telemetry` events are forwarded when `:ocel_ingest_url` is set:
  `[:ash_a2a, :dispatch, :stop]`, `[:ash_a2a, :dispatch, :exception]`
  (a dispatch that raised inside its span -- OCEL event type
  `<dispatch type>.exception`, carrying `kind`, a redacted `error_code` and
  the duration, never a stacktrace), `[:ash_a2a, :receipt, :committed]` and
  `[:ash_a2a, :receipt, :outboxed]`.

  ## Egress hygiene

  The ingest URL is reduced to a credential-free endpoint
  (`AshA2A.Telemetry.Redact.endpoint/1`) before it reaches any log line or
  telemetry metadata. Error terms in event bodies are redacted summaries
  (`AshA2A.Telemetry.Redact.error_summary/1`). Response bodies are never
  logged unless `config :ash_a2a, :ocel_log_body, true` (then only the first
  200 bytes). Delivery-failure warnings are rate-limited to one per
  `:ocel_log_interval_ms` (default 60_000); the next emitted warning carries
  the number suppressed in between.

  ## Delivery accounting

    * `[:ash_a2a, :ocel, :delivered]` -- `%{duration: native}`,
      `%{endpoint: String.t()}`; counted by `delivered_count/0`.
    * `[:ash_a2a, :ocel, :failed]` -- `%{duration: native}`,
      `%{endpoint: String.t(), status: pos_integer() | nil, reason: atom()}`;
      counted by `failed_count/0`.
    * `[:ash_a2a, :ocel, :shed]` -- `%{count: 1}`, `%{endpoint: String.t(), reason:
      term()}`; counted by `shed_count/0`. (Before OBS-02 this metadata carried
      the raw `:url`; it now carries only the sanitized `:endpoint`.)
  """

  require Logger

  @dispatch_handler_id {__MODULE__, :dispatch_stop}
  @receipt_handler_id {__MODULE__, :receipt_committed}
  @outboxed_handler_id {__MODULE__, :receipt_outboxed}
  @exception_handler_id {__MODULE__, :dispatch_exception}
  @shed_counter_key {__MODULE__, :shed_counter}
  # One `:counters` array for delivery accounting: 1 = delivered, 2 = failed,
  # 3 = warnings suppressed by the log rate limit since the last warning.
  @delivery_counter_key {__MODULE__, :delivery_counters}
  @last_warning_key {__MODULE__, :last_warning_at}
  @delivered_ix 1
  @failed_ix 2
  @suppressed_ix 3

  @spec attach!() :: :ok
  def attach! do
    :ok = attach(@dispatch_handler_id, [:ash_a2a, :dispatch, :stop])
    :ok = attach(@exception_handler_id, [:ash_a2a, :dispatch, :exception])
    :ok = attach(@receipt_handler_id, [:ash_a2a, :receipt, :committed])
    :ok = attach(@outboxed_handler_id, [:ash_a2a, :receipt, :outboxed])
    :ok
  end

  @spec detach() :: :ok | {:error, :not_found}
  def detach do
    results = [
      :telemetry.detach(@dispatch_handler_id),
      :telemetry.detach(@exception_handler_id),
      :telemetry.detach(@receipt_handler_id),
      :telemetry.detach(@outboxed_handler_id)
    ]

    if :ok in results, do: :ok, else: {:error, :not_found}
  end

  @doc """
  Total OCEL events that could not be admitted to the bounded forwarding task
  supervisor. Every such drop increments this counter and emits one
  `[:ash_a2a, :ocel, :shed]` telemetry event.
  """
  @spec shed_count() :: non_neg_integer()
  def shed_count do
    case :persistent_term.get(@shed_counter_key, nil) do
      nil -> 0
      ref -> :counters.get(ref, 1)
    end
  end

  @doc """
  Total OCEL events the ingest accepted with a 2xx status.
  """
  @spec delivered_count() :: non_neg_integer()
  def delivered_count, do: read_delivery_counter(@delivered_ix)

  @doc """
  Total OCEL events that were admitted for forwarding but not delivered
  (non-2xx status, transport error, or an unexpected raise). Every such loss
  increments this counter and emits one `[:ash_a2a, :ocel, :failed]` event.
  """
  @spec failed_count() :: non_neg_integer()
  def failed_count, do: read_delivery_counter(@failed_ix)

  defp read_delivery_counter(ix) do
    case :persistent_term.get(@delivery_counter_key, nil) do
      nil -> 0
      ref -> :counters.get(ref, ix)
    end
  end

  @doc false
  def handle_event([:ash_a2a, :dispatch, :exception], measurements, metadata, _config) do
    case ingest_url() do
      nil -> :ok
      url -> async_post_event(url, build_exception_event(measurements, metadata))
    end
  end

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

  @doc "Configured OCEL ingest URL: `config :ash_a2a, :ocel_ingest_url` (default `nil` = forwarding disabled)."
  @spec ingest_url() :: String.t() | nil
  def ingest_url, do: Application.get_env(:ash_a2a, :ocel_ingest_url)

  defp async_post_event(url, event) do
    # OBS-12: Task.Supervisor children do not inherit Logger metadata; carry
    # the dispatching process's correlation keys into the POST task.
    logger_metadata = Logger.metadata()

    result =
      try do
        Task.Supervisor.start_child(task_supervisor(), fn ->
          Logger.metadata(logger_metadata)
          post_event(url, event)
        end)
      rescue
        error -> {:error, {:task_supervisor_error, error}}
      catch
        :exit, reason -> {:error, {:task_supervisor_exit, reason}}
      end

    case result do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        shed_event(url, reason)
        :ok
    end
  end

  @doc "Concurrent-POST ceiling: `config :ash_a2a, :ocel_max_in_flight` (default `256`)."
  def max_in_flight, do: Application.get_env(:ash_a2a, :ocel_max_in_flight, 256)

  @doc "Forwarder HTTP timeout: `config :ash_a2a, :ocel_ingest_timeout_ms` (default `2_000`)."
  def ingest_timeout_ms, do: Application.get_env(:ash_a2a, :ocel_ingest_timeout_ms, 2_000)

  @doc "Body-logging switch: `config :ash_a2a, :ocel_log_body` (default `false`)."
  def log_body?, do: Application.get_env(:ash_a2a, :ocel_log_body, false) == true

  @doc "Warning-throttle interval: `config :ash_a2a, :ocel_log_interval_ms` (default `60_000`)."
  def log_interval_ms, do: Application.get_env(:ash_a2a, :ocel_log_interval_ms, 60_000)

  @doc "Forwarder task supervisor name: `config :ash_a2a, :ocel_task_supervisor` (default `AshA2A.Telemetry.TaskSupervisor`)."
  def task_supervisor, do: Application.get_env(:ash_a2a, :ocel_task_supervisor, AshA2A.Telemetry.TaskSupervisor)

  defp shed_event(url, reason) do
    :counters.add(shed_counter(), 1, 1)

    :telemetry.execute([:ash_a2a, :ocel, :shed], %{count: 1}, %{
      endpoint: AshA2A.Telemetry.Redact.endpoint(url),
      reason: reason
    })

    :ok
  end

  defp delivery_counters do
    case :persistent_term.get(@delivery_counter_key, nil) do
      nil ->
        ref = :counters.new(3, [:write_concurrency])
        :persistent_term.put(@delivery_counter_key, ref)
        ref

      ref ->
        ref
    end
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
    endpoint = AshA2A.Telemetry.Redact.endpoint(url)
    started = System.monotonic_time()

    outcome =
      try do
        case AshA2A.Egress.EndpointPolicy.admit(url, [allow_userinfo: true] ++ egress_policy()) do
          {:ok, admitted} ->
            AshA2A.Egress.EndpointPolicy.request_options(admitted, "/ocel/events")
            |> Keyword.merge(json: %{"events" => [event]}, receive_timeout: receive_timeout_ms())
            |> Req.post()

          {:error, code, _detail} ->
            {:refused, code}
        end
      rescue
        error -> {:raised, error}
      catch
        kind, _reason -> {:raised, kind}
      end

    duration = System.monotonic_time() - started
    account(outcome, endpoint, duration)
  end

  defp account({:refused, code}, endpoint, duration) do
    failed(endpoint, duration, nil, code, fn ->
      "OCEL egress to #{endpoint} refused by endpoint policy: #{code}"
    end)
  end

  defp account({:ok, %Req.Response{status: status}}, endpoint, duration)
       when status in 200..299 do
    :counters.add(delivery_counters(), @delivered_ix, 1)

    :telemetry.execute([:ash_a2a, :ocel, :delivered], %{duration: duration}, %{endpoint: endpoint})

    :ok
  end

  defp account({:ok, %Req.Response{status: status, body: body}}, endpoint, duration) do
    failed(endpoint, duration, status, :non_2xx, fn ->
      "ingest at #{endpoint} returned non-2xx status #{status}#{body_excerpt(body)}"
    end)
  end

  defp account({:error, reason}, endpoint, duration) do
    code = transport_reason(reason)

    failed(endpoint, duration, nil, code, fn ->
      "failed to forward OCEL event to #{endpoint}: #{code}"
    end)
  end

  defp account({:raised, error}, endpoint, duration) do
    failed(endpoint, duration, nil, :raised, fn ->
      "unexpected error forwarding OCEL event to #{endpoint}: " <>
        inspect(AshA2A.Telemetry.Redact.error_summary(error))
    end)
  end

  defp failed(endpoint, duration, status, reason, message_fun) do
    :counters.add(delivery_counters(), @failed_ix, 1)

    :telemetry.execute([:ash_a2a, :ocel, :failed], %{duration: duration}, %{
      endpoint: endpoint,
      status: status,
      reason: reason
    })

    rate_limited_warning(message_fun)
    :ok
  end

  # `Req.TransportError`/`Mint` reasons are atoms such as `:econnrefused` or
  # `:timeout`; anything else is reduced to its summary kind.
  defp transport_reason(%{reason: reason}) when is_atom(reason), do: reason
  defp transport_reason(reason), do: AshA2A.Telemetry.Redact.error_summary(reason).kind

  defp body_excerpt(body) do
    if log_body?() do
      text = if is_binary(body), do: body, else: inspect(body, limit: 20)
      ": " <> binary_part(text, 0, min(byte_size(text), 200))
    else
      ""
    end
  end

  @doc false
  # At most one warning per `:ocel_log_interval_ms`; the count of warnings
  # suppressed in between is reported on the next emitted one. The check is
  # racy across concurrent POST tasks by design (a rare duplicate warning is
  # acceptable; an unbounded warning flood is not).
  def rate_limited_warning(message_fun) do
    interval = log_interval_ms()
    now = System.monotonic_time(:millisecond)
    last = :persistent_term.get(@last_warning_key, nil)

    if is_nil(last) or now - last >= interval do
      :persistent_term.put(@last_warning_key, now)
      ref = delivery_counters()
      suppressed = :counters.get(ref, @suppressed_ix)
      :counters.sub(ref, @suppressed_ix, suppressed)

      suffix =
        if suppressed > 0, do: " (#{suppressed} similar warnings suppressed)", else: ""

      Logger.warning("AshA2A.Telemetry.OcelForwarder: " <> message_fun.() <> suffix)
    else
      :counters.add(delivery_counters(), @suppressed_ix, 1)
    end

    :ok
  end

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
        |> Map.put("error", ocel_error(Map.get(metadata, :error)))
    end
  end

  # OBS-01: the OCEL body leaves the VM; it carries only the error KIND, even
  # when a host opted into raw in-VM telemetry errors.
  defp ocel_error(%{kind: :exception, exception: module}) when is_atom(module),
    do: "exception:" <> inspect(module)

  defp ocel_error(error), do: error |> AshA2A.Telemetry.Redact.error_summary() |> error_code()

  defp error_code(%{kind: :exception, exception: module}), do: "exception:" <> inspect(module)
  defp error_code(%{kind: kind}), do: to_string(kind)

  defp build_exception_event(measurements, metadata) do
    %{
      "event_id" => Ash.UUIDv7.generate(),
      "event_type" => event_type(metadata) <> ".exception",
      "event_time" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "attributes" => %{
        "skill_name" => to_string(Map.get(metadata, :skill_name)),
        "resource_or_domain" => inspect(Map.get(metadata, :resource_or_domain)),
        "kind" => metadata |> Map.get(:kind) |> to_string_or_nil(),
        "error_code" => metadata |> Map.get(:reason) |> ocel_error(),
        "duration_native" => measurements |> Map.get(:duration) |> to_string_or_nil()
      },
      "relationships" => relationships(metadata)
    }
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)

  # SSRF policy for the ingest URL (CWE-918). Strict by default (https, public
  # addresses only). Override with `config :ash_a2a, :ocel_egress_policy,
  # allow_http: true, allow_cidrs: [...]` for a trusted internal collector.
  # Under Mix env :test the default admits loopback http so the suite's local
  # ingest listeners work; the egress court sets the policy explicitly.
  @default_egress_policy if Mix.env() == :test,
                           do: [allow_http: true, allow_cidrs: ["127.0.0.0/8", "::1/128"]],
                           else: []

  defp egress_policy do
    case Application.fetch_env(:ash_a2a, :ocel_egress_policy) do
      {:ok, policy} when is_list(policy) -> policy
      _ -> @default_egress_policy
    end
  end

  defp receive_timeout_ms, do: ingest_timeout_ms()
end
