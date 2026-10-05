# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Telemetry.SIEM do
  @moduledoc """
  Direct, resilient HTTP egress adapters for enterprise SIEM platforms
  (PRD v26.10.4 FR-06.4): Splunk HEC, Google Chronicle and Datadog Logs.

  ## Payload: IEEE OCEL v2, consumed read-only

  Adapters accept the event maps already produced by the existing
  serialization capital -- `AshA2A.Telemetry.OcelForwarder` (dispatch and
  receipt events) and `AshA2A.SemanticProjection.ocel_event/1` -- and
  transport them without re-deriving anything: string-keyed maps with
  `"event_id"`, `"event_type"`, `"event_time"`, `"attributes"` (a map) and
  optional `"relationships"` (a list). `deliver/3` validates this shape
  fail-closed before any HTTP connection is made; the OCEL v2 object is the
  payload, not a log line flattened out of it.

  ## Batch + flush semantics

  `deliver/3` drains the caller's full event list in `:batch_size` chunks
  (default `500`), one HTTP request per batch, in order. A batch failure
  stops the drain (fail-fast): the typed error carries which batch failed,
  how many batches flushed before it, and how many events remain unflushed,
  so a caller retries only the remainder. An empty event list validates
  config and events, sends nothing, and returns a zero report.

  ## Resilient delivery

  Each batch is attempted up to `1 + :max_retries` times (default `1 + 2`).
  Retryable failures -- 500..599, 408, 429 and transport errors (timeouts,
  connection refused) -- back off exponentially
  (`:backoff_base_ms * 2^(attempt-1)`, capped at `:max_backoff_ms`; defaults
  `50`ms / `2_000`ms). Non-retryable 4xx (except 408/429) fails the batch on
  its first attempt. Every exhaustion -- and every unexpected raise anywhere
  in the pipeline -- collapses into the typed
  `{:error, {:siem_delivery_failed, platform, reason}}`; delivery never
  crashes the broadcaster, so telemetry egress can never take down the
  dispatch path it observes.

  ## Endpoint admission and mTLS via the harness

  Every request is admitted by `AshA2A.Egress.EndpointPolicy` (CWE-918:
  https-only and public addresses by default, connection pinned to the
  admitted IP, no redirects) with `:siem_egress_policy` overrides (same
  shape as `:ocel_egress_policy`). mTLS is supplied by the calling harness
  through `:transport_opts` -- standard `:ssl` options such as
  `cacertfile`/`certfile`/`keyfile`/`verify` -- validated fail-closed (each
  configured file must exist) and merged into the pinned request's
  `:connect_options`. Errors carry only the redacted endpoint
  (`AshA2A.Telemetry.Redact.endpoint/1`), never credentials.

  Telemetry: `[:ash_a2a, :siem, :delivered]` (`%{events, duration}`,
  `%{platform, endpoint}`) and `[:ash_a2a, :siem, :failed]`
  (`%{events, duration}`, `%{platform, endpoint, reason}`).
  """

  alias AshA2A.Egress.EndpointPolicy
  alias AshA2A.Telemetry.Redact
  alias AshA2A.Telemetry.SIEM.{Chronicle, DatadogLogs, SplunkHEC}

  @type platform :: :splunk_hec | :chronicle | :datadog_logs

  @typedoc "Report on `{:ok, report}` from `deliver/3`."
  @type report :: %{
          required(:platform) => platform(),
          required(:events) => non_neg_integer(),
          required(:batches) => non_neg_integer(),
          required(:http_requests) => non_neg_integer(),
          required(:attempts) => non_neg_integer()
        }

  @typedoc "Fail-fast failure detail: which batch, what flushed, what remains."
  @type failure_detail :: %{
          required(:batch) => pos_integer(),
          required(:attempts) => pos_integer(),
          required(:flushed_batches) => non_neg_integer(),
          required(:unflushed_events) => non_neg_integer(),
          required(:reason) => term()
        }

  @type delivery_error :: {:error, {:siem_delivery_failed, platform(), failure_detail()}}
  @type config_error :: {:error, {:siem_config_invalid, platform(), term()}}

  @doc "OCEL v2 keys every event must carry before it is allowed on the wire."
  @required_keys ~w(event_id event_type event_time)

  # -- behaviour -------------------------------------------------------------

  @callback platform() :: platform()

  @doc "Fail-closed validation of the platform's endpoint config."
  @callback validate_config(keyword()) :: {:ok, keyword()} | {:error, term()}

  @doc """
  One HTTP attempt for `events` (already one batch). Returns the admitted
  status on 2xx, or `{:error, {:http_status, status}}`,
  `{:error, {:transport, kind}}` or `{:error, {:endpoint_refused, code, detail}}`.
  """
  @callback send_events([map()], keyword()) :: {:ok, pos_integer()} | {:error, term()}

  @adapters %{
    splunk_hec: SplunkHEC,
    chronicle: Chronicle,
    datadog_logs: DatadogLogs
  }

  @doc "Platform -> adapter registry; an adapter module passes through unchanged."
  @spec adapter(platform() | module()) :: {:ok, module()} | {:error, :unknown_platform}
  def adapter(platform_or_module)

  def adapter(module) when module in [SplunkHEC, Chronicle, DatadogLogs], do: {:ok, module}

  def adapter(platform) when is_atom(platform) do
    case Map.fetch(@adapters, platform) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :unknown_platform}
    end
  end

  def adapter(_other), do: {:error, :unknown_platform}

  @doc """
  Delivers `events` (IEEE OCEL v2 maps; module doc) to `platform`
  (`:splunk_hec`, `:chronicle`, `:datadog_logs`, or an adapter module)
  via `config`. Batch/flush and retry semantics in the module doc.
  """
  @spec deliver(platform() | module(), [map()], keyword()) ::
          {:ok, report()}
          | delivery_error()
          | config_error()
          | {:error, {:siem_invalid_event, platform(), pos_integer(), [String.t()]}}
  def deliver(platform_or_module, events, config) when is_list(events) and is_list(config) do
    with {:ok, adapter} <- adapter(platform_or_module),
         platform = adapter.platform(),
         {:ok, config} <- validate_with(adapter, platform, config),
         {:ok, batches, event_count} <-
           ocel_batches(events, platform, opt(config, :batch_size, 500)) do
      started = System.monotonic_time()

      run_batches(adapter, platform, batches, config, %{
        platform: platform,
        events: event_count,
        batches: length(batches),
        http_requests: 0,
        attempts: 0
      })
      |> emit_telemetry(platform, config, started)
    end
  end

  defp validate_with(adapter, platform, config) do
    case adapter.validate_config(config) do
      {:ok, config} -> {:ok, config}
      {:error, reason} -> {:error, {:siem_config_invalid, platform, reason}}
    end
  end

  @doc "Config value with a default: `opt(config, :max_retries, 2)`."
  @spec opt(keyword(), atom(), term()) :: term()
  def opt(config, key, default), do: Keyword.get(config, key, default)

  # -- shared config validation (fail-closed) --------------------------------

  @doc """
  Common config validation for every adapter: endpoint, retry/backoff,
  batch, timeout and mTLS `:transport_opts` (fail-closed on missing files).
  Returns `:ok` or `{:error, reason}`.
  """
  @spec common_config(keyword()) :: :ok | {:error, term()}
  def common_config(config) when is_list(config) do
    with :ok <- validate_endpoint(config[:endpoint]),
         :ok <- validate_non_neg(config, :max_retries),
         :ok <- validate_pos(config, :batch_size),
         :ok <- validate_non_neg(config, :backoff_base_ms),
         :ok <- validate_non_neg(config, :max_backoff_ms),
         :ok <- validate_pos(config, :timeout_ms),
         :ok <- validate_transport_opts(config[:transport_opts]) do
      :ok
    end
  end

  def common_config(_other), do: {:error, :config_not_keyword}

  @doc "Fails closed unless `config[key]` is a non-empty binary credential."
  @spec require_credential(keyword(), atom()) :: :ok | {:error, {:missing_credential, atom()}}
  def require_credential(config, key) do
    case config[key] do
      value when is_binary(value) and value != "" -> :ok
      _ -> {:error, {:missing_credential, key}}
    end
  end

  @doc "Rejects a present-but-not-binary optional binary option."
  @spec optional_binary(keyword(), atom()) :: :ok | {:error, {atom(), :not_a_binary}}
  def optional_binary(config, key) do
    case config[key] do
      nil -> :ok
      value when is_binary(value) -> :ok
      _ -> {:error, {key, :not_a_binary}}
    end
  end

  # -- shared HTTP machinery (one pinned, admitted Req post per batch) -------

  @doc false
  @spec request(keyword(), String.t(), [{binary(), binary()}], binary(), keyword()) ::
          {:ok, pos_integer()} | {:error, term()}
  def request(config, path, headers, body, opts \\ []) do
    url = Keyword.fetch!(config, :endpoint)

    case EndpointPolicy.admit(url, Keyword.merge(egress_policy(), allow_userinfo: false)) do
      {:ok, admitted} ->
        base = EndpointPolicy.request_options(admitted, path)

        request_opts =
          base
          |> Keyword.put(:headers, Keyword.get(base, :headers, []) ++ headers)
          |> Keyword.put(:body, body)
          |> Keyword.put(:retry, false)
          |> Keyword.put(:receive_timeout, opt(config, :timeout_ms, 2_000))
          |> maybe_put(:params, opts[:params])
          |> Keyword.put(
            :connect_options,
            merge_connect_options(base[:connect_options], config[:transport_opts] || [])
          )

        case Req.post(request_opts) do
          {:ok, %Req.Response{status: status}} when status in 200..299 -> {:ok, status}
          {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
          {:error, err} -> {:error, {:transport, transport_kind(err)}}
        end

      {:error, code, detail} ->
        {:error, {:endpoint_refused, code, detail}}
    end
  end

  # -- shared ndjson / batch machinery ----------------------------------------

  @doc "Encodes one ndjson batch: events joined by newlines with a trailing newline."
  @spec ndjson([map()]) :: String.t()
  def ndjson(events) do
    events
    |> Enum.map(&Jason.encode!/1)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  @doc """
  Validates every event's OCEL v2 shape fail-closed and chunks into
  `batch_size` event batches. Returns `{:ok, batches, event_count}` or
  `{:error, {:siem_invalid_event, platform, index, missing_keys}}`.
  """
  @spec ocel_batches([map()], platform(), pos_integer()) ::
          {:ok, [[map()]], non_neg_integer()}
          | {:error, {:siem_invalid_event, platform(), pos_integer(), [String.t()]}}
  def ocel_batches(events, platform, batch_size) do
    with :ok <- validate_events(events, platform, 0) do
      {:ok, Enum.chunk_every(events, batch_size), length(events)}
    end
  end

  defp validate_events([], _platform, _ix), do: :ok

  defp validate_events([event | rest], platform, ix) do
    case event_shape_errors(event) do
      [] -> validate_events(rest, platform, ix + 1)
      missing -> {:error, {:siem_invalid_event, platform, ix + 1, missing}}
    end
  end

  defp event_shape_errors(event) when is_map(event) do
    @required_keys
    |> Enum.reject(&is_map_key(event, &1))
    |> Enum.concat(missing_shape(event))
  end

  defp event_shape_errors(_other), do: ["not_a_map"]

  defp missing_shape(event) when is_map(event) do
    [] =
      []
      |> maybe_prepend(
        is_map_key(event, "attributes") and not is_map(event["attributes"]),
        "attributes_not_a_map"
      )
      |> maybe_prepend(
        is_map_key(event, "relationships") and not is_list(event["relationships"]),
        "relationships_not_a_list"
      )
  end

  defp missing_shape(_other), do: ["not_a_map"]

  defp maybe_prepend(list, true, item), do: [item | list]
  defp maybe_prepend(list, false, _item), do: list

  # -- retry + batch drain -----------------------------------------------------

  defp run_batches(_adapter, _platform, [], _config, acc), do: {:ok, acc}

  defp run_batches(adapter, platform, batches, config, acc) do
    batches
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, acc}, fn {batch, index}, {:ok, acc} ->
      case attempt_with_retry(adapter, batch, config) do
        {:ok, %{attempts: attempts}} ->
          {:cont,
           {:ok,
            %{
              acc
              | http_requests: acc.http_requests + 1,
                attempts: acc.attempts + attempts
            }}}

        {:error, %{attempts: attempts, reason: reason}} ->
          remaining = batches |> Enum.drop(index) |> List.flatten() |> length()

          {:halt,
           {:error,
            {:siem_delivery_failed, platform,
             %{
               batch: index,
               attempts: acc.attempts + attempts,
               flushed_batches: index - 1,
               unflushed_events: remaining,
               reason: reason
             }}}}
      end
    end)
  end

  defp attempt_with_retry(adapter, batch, config) do
    attempt_with_retry(adapter, batch, config, opt(config, :max_retries, 2), 1)
  end

  defp attempt_with_retry(adapter, batch, config, retries_left, attempt) do
    case adapter.send_events(batch, config) do
      {:ok, _status} ->
        {:ok, %{attempts: attempt}}

      {:error, reason} ->
        if retries_left > 0 and retryable?(reason) do
          backoff(config, attempt)
          attempt_with_retry(adapter, batch, config, retries_left - 1, attempt + 1)
        else
          {:error, %{attempts: attempt, reason: reason}}
        end
    end
  end

  defp retryable?({:http_status, status}) when is_integer(status) do
    status in [408, 429] or status in 500..599
  end

  defp retryable?({:transport, _kind}), do: true
  defp retryable?({:endpoint_refused, _code, _detail}), do: false
  defp retryable?(_other), do: false

  defp backoff(config, attempt) do
    base = opt(config, :backoff_base_ms, 50)
    cap = opt(config, :max_backoff_ms, 2_000)

    base
    |> Kernel.*(2 ** (attempt - 1))
    |> min(cap)
    |> max(0)
    |> then(&Process.sleep/1)
  end

  defp transport_kind(%{reason: reason}) when is_atom(reason), do: reason
  defp transport_kind(err), do: Redact.error_summary(err).kind

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp merge_connect_options(nil, tls), do: [transport_opts: tls]
  defp merge_connect_options(base, tls), do: Keyword.merge(base, transport_opts: tls)

  # SSRF policy for SIEM endpoints (CWE-918); same shape as :ocel_egress_policy.
  # Under Mix env :test the default admits loopback http so the suite's local
  # receivers work; prod default is strict (https, public only).
  @default_egress_policy if Mix.env() == :test,
                           do: [allow_http: true, allow_cidrs: ["127.0.0.0/8", "::1/128"]],
                           else: []

  defp egress_policy do
    case Application.fetch_env(:ash_a2a, :siem_egress_policy) do
      {:ok, policy} when is_list(policy) -> policy
      _ -> @default_egress_policy
    end
  end

  # -- config validation helpers ------------------------------------------------

  defp validate_endpoint(endpoint) do
    with value when is_binary(value) and value != "" <- endpoint || {:error, :endpoint_missing},
         {:ok, %URI{scheme: scheme, host: host}}
         when scheme in ~w(http https) and is_binary(host) and host != "" <- URI.new(value) do
      :ok
    else
      {:error, :endpoint_missing} -> {:error, :endpoint_missing}
      {:error, %URI.Error{}} -> {:error, {:invalid_endpoint, :unparseable}}
      _ -> {:error, {:invalid_endpoint, :scheme_or_host}}
    end
  end

  defp validate_non_neg(config, key) do
    case config[key] do
      nil -> :ok
      value when is_integer(value) and value >= 0 -> :ok
      _ -> {:error, {key, :not_a_non_negative_integer}}
    end
  end

  defp validate_pos(config, key) do
    case config[key] do
      nil -> :ok
      value when is_integer(value) and value > 0 -> :ok
      _ -> {:error, {key, :not_a_positive_integer}}
    end
  end

  @tls_file_keys [:cacertfile, :certfile, :keyfile]
  @tls_verify_values [:verify_peer, :verify_none]

  defp validate_transport_opts(nil), do: :ok
  defp validate_transport_opts([]), do: :ok

  defp validate_transport_opts(opts) when is_list(opts) do
    with :ok <- validate_tls_files(opts),
         :ok <- validate_tls_verify(opts[:verify]) do
      :ok
    end
  end

  defp validate_transport_opts(_other), do: {:error, {:transport_opts, :not_a_keyword}}

  defp validate_tls_files(opts) do
    Enum.reduce_while(@tls_file_keys, :ok, fn key, :ok ->
      case opts[key] do
        nil ->
          {:cont, :ok}

        path when is_binary(path) ->
          if File.exists?(path) do
            {:cont, :ok}
          else
            {:halt, {:error, {:transport_opts_file_missing, key, path}}}
          end

        _other ->
          {:halt, {:error, {:transport_opts, {key, :not_a_binary}}}}
      end
    end)
  end

  defp validate_tls_verify(nil), do: :ok
  defp validate_tls_verify(value) when value in @tls_verify_values, do: :ok
  defp validate_tls_verify(_other), do: {:error, {:transport_opts, {:verify, :invalid}}}

  # -- telemetry -----------------------------------------------------------------

  defp emit_telemetry({:ok, report}, platform, config, started) do
    :telemetry.execute(
      [:ash_a2a, :siem, :delivered],
      %{
        events: report.events,
        duration: System.monotonic_time() - started
      },
      %{platform: platform, endpoint: Redact.endpoint(config[:endpoint])}
    )

    {:ok, report}
  end

  defp emit_telemetry({:error, _} = failure, platform, config, started) do
    :telemetry.execute(
      [:ash_a2a, :siem, :failed],
      %{events: 0, duration: System.monotonic_time() - started},
      %{
        platform: platform,
        endpoint: Redact.endpoint(config[:endpoint]),
        reason: failure
      }
    )

    failure
  end
end
