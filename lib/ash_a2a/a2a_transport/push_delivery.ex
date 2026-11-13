# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.A2ATransport.PushDelivery do
  @moduledoc """
  Webhook delivery for A2A push notifications.

  One delivery = one supervised task that POSTs a JSON payload (the A2A
  `Task` or `TaskStatusUpdateEvent` object) to a push config's `url`, with
  bounded exponential-backoff retries.

  ## Security

    * **SSRF**: every attempt re-admits the URL through
      `AshA2A.A2ATransport.WebhookPolicy` and then connects to the *admitted
      IP address* (the URL host is rewritten to the IP; `Host` and TLS
      SNI/certificate verification keep the original hostname via Mint's
      `:hostname` connect option). A DNS answer that changes between
      admission and connect therefore cannot redirect the request.
    * **No redirects** are followed (`redirect: false`): a 3xx is a failed
      attempt, never a hop to an unadmitted host.
    * **Authentication to the receiver**: the config's `token` is sent as
      `X-A2A-Notification-Token`; `authentication.schemes` containing
      `"Bearer"` with string `credentials` adds `Authorization: Bearer ...`.
    * **Signing**: when `:signing_secret` is configured, each request carries
      `X-A2A-Timestamp: <unix seconds>` and
      `X-A2A-Signature: v1=<hex HMAC-SHA256(secret, timestamp <> "." <> body)>`
      so the receiver can authenticate the sender and reject replays.
      `verify_signature/4` is the receiver-side check.

  ## Options (`push:` of `AshA2A.A2ATransport`)

    * `:allow_http`, `:allow_cidrs`, `:resolver` -- see `WebhookPolicy`.
    * `:signing_secret` -- binary HMAC key (default: none, unsigned).
    * `:max_attempts` (5), `:base_backoff_ms` (500), `:max_backoff_ms` (30_000).
    * `:receive_timeout` (5_000), `:connect_timeout` (5_000).

  Each attempt is recorded (`AshA2A.A2ATransport.TaskEvents.attempts/2`) and
  emitted as telemetry `[:ash_a2a, :a2a_transport, :push, :attempt]` with
  metadata `%{task_id, config_id, attempt, outcome}`.
  """

  alias AshA2A.A2ATransport
  alias AshA2A.A2ATransport.{TaskEvents, WebhookPolicy}

  @v11_event_keys ~w(generation timeline startGeneration endGeneration)

  @doc """
  The webhook body for `config` given a logged event, shaped by the config's
  `protocol_version` (default `"0.3"`: an absent version is `"0.3"` everywhere,
  matching the `A2A-Version` header gate, `AshA2A.Protocol.Version.parse_header/1`).

    * `>= 1.1`: the payload as logged (carries `generation`; `message-update`
      events are delivered).
    * `< 1.1`: `message-update` events are skipped (`:skip`) and the 1.1-only
      additions (`generation`, `timeline`, artifact `startGeneration` /
      `endGeneration`) are stripped from `task` / `statusUpdate` /
      `artifactUpdate` payloads.
  """
  @spec payload_for(map(), String.t(), map()) :: {:ok, map()} | :skip
  def payload_for(config, kind, payload) do
    cond do
      AshA2A.Protocol.Version.at_least?(Map.get(config, :protocol_version) || "0.3", "1.1") ->
        {:ok, payload}

      kind == "message-update" ->
        :skip

      true ->
        {:ok, strip_v11(payload)}
    end
  end

  defp strip_v11(%{} = payload) do
    Map.new(payload, fn
      {"task", %{} = task} ->
        task = Map.drop(task, @v11_event_keys)
        task =
          case Map.fetch(task, "artifacts") do
            {:ok, arts} -> Map.put(task, "artifacts", strip_artifacts(arts))
            :error -> Map.put(task, "artifacts", nil)
          end

        {"task", if(task["artifacts"] == nil, do: Map.delete(task, "artifacts"), else: task)}

      {"artifactUpdate", %{} = ev} ->
        ev = Map.drop(ev, @v11_event_keys)

        ev =
          case ev["artifact"] do
            %{} = a -> Map.put(ev, "artifact", Map.drop(a, @v11_event_keys))
            _ -> ev
          end

        {"artifactUpdate", ev}

      {"statusUpdate", %{} = ev} ->
        {"statusUpdate", Map.drop(ev, @v11_event_keys)}

      other ->
        other
    end)
  end

  defp strip_v11(other), do: other

  defp strip_artifacts(list) when is_list(list),
    do: Enum.map(list, fn a -> if is_map(a), do: Map.drop(a, @v11_event_keys), else: a end)

  defp strip_artifacts(other), do: other

  @doc "Starts a supervised delivery of `payload` to `config`."
  @spec start(atom(), map(), map(), non_neg_integer(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def start(transport, config, payload, seq, opts) do
    case Task.Supervisor.start_child(A2ATransport.push_sup_name(transport), fn ->
           deliver(transport, config, payload, seq, opts)
         end) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} = error ->
        dropped = if reason == :max_children, do: :max_deliveries, else: reason
        record(transport, config, 0, {:dropped, dropped})
        error
    end
  end

  @doc """
  Delivers synchronously with retries. Returns `:ok` on a 2xx or
  `{:error, last_outcome}` once attempts are exhausted or the URL is refused.
  """
  @spec deliver(atom(), map(), map(), non_neg_integer(), keyword()) :: :ok | {:error, term()}
  def deliver(transport, config, payload, seq, opts) do
    body = Jason.encode!(payload)
    delivery_id = "#{config.task_id}:#{config.id}:#{seq}"
    attempt(transport, config, body, delivery_id, opts, 1)
  end

  defp attempt(transport, config, body, delivery_id, opts, n) do
    max = Keyword.get(opts, :max_attempts, 5)
    {outcome, retry_after_ms} = post(config, body, delivery_id, opts)
    record(transport, config, n, outcome)

    case outcome do
      {:ok, _status} ->
        :ok

      {:refused, _code, _detail} = refused ->
        {:error, refused}

      # Permanent client errors (except 408/429) will not succeed on retry.
      {:http_error, status} = permanent when status in 400..499 and status not in [408, 429] ->
        {:error, permanent}

      other when n >= max ->
        {:error, other}

      _retryable ->
        # SLEEP-CLASS: SCHEDULING (delivery retry backoff, honoring Retry-After)
        Process.sleep(retry_delay(n, retry_after_ms, opts))
        attempt(transport, config, body, delivery_id, opts, n + 1)
    end
  end

  # Retry-After raises the delay floor, bounded by `:max_retry_after_ms`
  # (default 60_000) so a hostile receiver cannot park a worker indefinitely.
  defp retry_delay(n, nil, opts), do: backoff(n, opts)

  defp retry_delay(n, ra, opts),
    do: max(backoff(n, opts), min(ra, Keyword.get(opts, :max_retry_after_ms, 60_000)))

  @doc false
  # Parses a Retry-After header value (delta-seconds or HTTP-date) to ms.
  def parse_retry_after(nil), do: nil

  def parse_retry_after(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {secs, ""} when secs >= 0 ->
        secs * 1000

      _ ->
        try do
          date = value |> String.trim() |> to_charlist() |> :httpd_util.convert_request_date()

          case date do
            :bad_date ->
              nil

            dt ->
              diff =
                :calendar.datetime_to_gregorian_seconds(dt) -
                  :calendar.datetime_to_gregorian_seconds(:calendar.universal_time())

              max(diff, 0) * 1000
          end
        rescue
          _ -> nil
        end
    end
  end

  @doc false
  def backoff(n, opts) do
    base = Keyword.get(opts, :base_backoff_ms, 500)
    cap = Keyword.get(opts, :max_backoff_ms, 30_000)
    min(cap, base * Integer.pow(2, n - 1))
  end

  defp post(config, body, delivery_id, opts) do
    policy = Keyword.take(opts, [:allow_http, :allow_cidrs, :resolver, :allow_ports])

    case WebhookPolicy.admit(config.url, policy) do
      {:error, code, detail} ->
        {{:refused, code, detail}, nil}

      {:ok, %{uri: uri, addresses: [ip | _]}} ->
        request(uri, ip, config, body, delivery_id, opts)
    end
  end

  defp request(%URI{} = uri, ip, config, body, delivery_id, opts) do
    pinned = %{uri | host: ip_host(ip)} |> URI.to_string()

    headers =
      [
        {"content-type", "application/json"},
        {"host", host_header(uri)},
        {"x-a2a-delivery-id", delivery_id},
        {"x-a2a-event-id", event_id(delivery_id, config)}
      ]
      |> add_token(config)
      |> add_auth(config)
      |> add_signature(body, Keyword.get(opts, :signing_secret))

    result =
      Req.post(pinned,
        body: body,
        headers: headers,
        retry: false,
        redirect: false,
        decode_body: false,
        receive_timeout: Keyword.get(opts, :receive_timeout, 5_000),
        connect_options: [
          hostname: uri.host,
          timeout: Keyword.get(opts, :connect_timeout, 5_000)
        ]
      )

    case result do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        {{:ok, status}, nil}

      {:ok, %Req.Response{status: status} = resp} ->
        ra =
          resp
          |> Req.Response.get_header("retry-after")
          |> List.first()
          |> parse_retry_after()

        {{:http_error, status}, ra}

      {:error, exception} ->
        {{:transport_error, Exception.message(exception)}, nil}
    end
  end

  # Stable per-event id (task id + seq), identical across retries and configs,
  # so receivers can dedupe replays. delivery_id is "task:config:seq".
  defp event_id(delivery_id, config) do
    seq = delivery_id |> String.split(":") |> List.last()
    "#{config.task_id}:#{seq}"
  end

  defp ip_host({_, _, _, _} = ip), do: ip |> :inet.ntoa() |> to_string()
  defp ip_host(ip), do: "[" <> (ip |> :inet.ntoa() |> to_string()) <> "]"

  defp host_header(%URI{host: host, port: port, scheme: scheme}) do
    if URI.default_port(scheme) == port, do: host, else: "#{host}:#{port}"
  end

  defp add_token(headers, %{token: token}) when is_binary(token) and token != "",
    do: [{"x-a2a-notification-token", token} | headers]

  defp add_token(headers, _), do: headers

  @doc """
  Authentication scheme classification shared with `PushConfigRPC` (set-time
  validation) so a scheme accepted at set is always sendable at delivery.

  Returns `{:ok, canonical}` where canonical is `:bearer | :basic | :api_key |
  {:generic, "Scheme"}`; `{:error, :mtls}` for mutual-TLS (not expressible as a
  header); `{:error, :unsupported}` otherwise.
  """
  @iana_schemes ~w(Digest Negotiate HOBA Mutual SCRAM-SHA-1 SCRAM-SHA-256 vapid DPoP GNAP PrivateToken Concealed)
  @spec classify_scheme(term()) :: {:ok, term()} | {:error, :mtls | :unsupported}
  def classify_scheme(scheme) when is_binary(scheme) do
    down = String.downcase(scheme)

    cond do
      down in ["bearer", "oauth2", "oauth", "oidc", "openidconnect"] -> {:ok, :bearer}
      down == "basic" -> {:ok, :basic}
      down in ["apikey", "api-key", "api_key"] -> {:ok, :api_key}
      down in ["mtls", "mutualtls", "mutual-tls", "mutual_tls"] -> {:error, :mtls}
      true ->
        case Enum.find(@iana_schemes, &(String.downcase(&1) == down)) do
          nil -> {:error, :unsupported}
          canonical -> {:ok, {:generic, canonical}}
        end
    end
  end

  def classify_scheme(_), do: {:error, :unsupported}

  # Normalizes the singular `scheme` / plural `schemes` forms, then sends the
  # first sendable scheme.
  defp add_auth(headers, %{authentication: %{"credentials" => creds} = auth})
       when is_binary(creds) do
    schemes =
      case auth do
        %{"schemes" => l} when is_list(l) -> l
        %{"scheme" => s} when is_binary(s) -> [s]
        _ -> []
      end

    schemes
    |> Enum.find_value(fn s ->
      case classify_scheme(to_string(s)) do
        {:ok, kind} -> kind
        _ -> nil
      end
    end)
    |> case do
      :bearer -> [{"authorization", "Bearer " <> creds} | headers]
      :basic -> [{"authorization", "Basic " <> creds} | headers]
      :api_key -> [{"x-api-key", creds} | headers]
      {:generic, name} -> [{"authorization", name <> " " <> creds} | headers]
      nil -> headers
    end
  end

  defp add_auth(headers, _), do: headers

  defp add_signature(headers, _body, nil), do: headers

  defp add_signature(headers, body, secret) when is_binary(secret) do
    ts = System.system_time(:second) |> Integer.to_string()

    [{"x-a2a-timestamp", ts}, {"x-a2a-signature", "v1=" <> sign(secret, ts, body)} | headers]
  end

  @doc "HMAC-SHA256 signature over `timestamp <> \".\" <> body`, lowercase hex."
  @spec sign(binary(), String.t(), binary()) :: String.t()
  def sign(secret, timestamp, body),
    do: :crypto.mac(:hmac, :sha256, secret, [timestamp, ".", body]) |> Base.encode16(case: :lower)

  @doc """
  Receiver-side verification of `X-A2A-Signature`. Refuses signatures older
  than `tolerance_s` seconds (default 300). Constant-time comparison.
  """
  @spec verify_signature(binary(), String.t(), String.t(), binary(), non_neg_integer()) ::
          :ok | {:error, :bad_signature | :stale_timestamp}
  def verify_signature(secret, timestamp, signature, body, tolerance_s \\ 300)

  def verify_signature(secret, timestamp, "v1=" <> sig, body, tolerance_s)
      when is_binary(secret) and is_binary(timestamp) do
    with {ts, ""} <- Integer.parse(timestamp),
         true <- abs(System.system_time(:second) - ts) <= tolerance_s || :stale,
         true <- Plug.Crypto.secure_compare(sign(secret, timestamp, body), sig) do
      :ok
    else
      :stale -> {:error, :stale_timestamp}
      _ -> {:error, :bad_signature}
    end
  end

  def verify_signature(_secret, _timestamp, _signature, _body, _tolerance_s),
    do: {:error, :bad_signature}

  defp record(transport, config, n, outcome) do
    attempt = %{config_id: config.id, attempt: n, outcome: outcome, at: DateTime.utc_now()}
    TaskEvents.record_attempt(transport, config.task_id, attempt)

    :telemetry.execute(
      [:ash_a2a, :a2a_transport, :push, :attempt],
      %{count: 1},
      %{task_id: config.task_id, config_id: config.id, attempt: n, outcome: outcome}
    )
  end
end
