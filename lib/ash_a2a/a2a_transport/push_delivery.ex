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
    outcome = post(config, body, delivery_id, opts)
    record(transport, config, n, outcome)

    case outcome do
      {:ok, _status} ->
        :ok

      {:refused, _code, _detail} = refused ->
        {:error, refused}

      other when n >= max ->
        {:error, other}

      _retryable ->
        Process.sleep(backoff(n, opts))
        attempt(transport, config, body, delivery_id, opts, n + 1)
    end
  end

  @doc false
  def backoff(n, opts) do
    base = Keyword.get(opts, :base_backoff_ms, 500)
    cap = Keyword.get(opts, :max_backoff_ms, 30_000)
    min(cap, base * Integer.pow(2, n - 1))
  end

  defp post(config, body, delivery_id, opts) do
    policy = Keyword.take(opts, [:allow_http, :allow_cidrs, :resolver])

    case WebhookPolicy.admit(config.url, policy) do
      {:error, code, detail} ->
        {:refused, code, detail}

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
        {"x-a2a-delivery-id", delivery_id}
      ]
      |> add_token(config)
      |> add_bearer(config)
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
      {:ok, %Req.Response{status: status}} when status in 200..299 -> {:ok, status}
      {:ok, %Req.Response{status: status}} -> {:http_error, status}
      {:error, exception} -> {:transport_error, Exception.message(exception)}
    end
  end

  defp ip_host({_, _, _, _} = ip), do: ip |> :inet.ntoa() |> to_string()
  defp ip_host(ip), do: "[" <> (ip |> :inet.ntoa() |> to_string()) <> "]"

  defp host_header(%URI{host: host, port: port, scheme: scheme}) do
    if URI.default_port(scheme) == port, do: host, else: "#{host}:#{port}"
  end

  defp add_token(headers, %{token: token}) when is_binary(token) and token != "",
    do: [{"x-a2a-notification-token", token} | headers]

  defp add_token(headers, _), do: headers

  defp add_bearer(headers, %{authentication: %{"schemes" => schemes, "credentials" => creds}})
       when is_list(schemes) and is_binary(creds) do
    if Enum.any?(schemes, &(String.downcase(to_string(&1)) == "bearer")),
      do: [{"authorization", "Bearer " <> creds} | headers],
      else: headers
  end

  defp add_bearer(headers, _), do: headers

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
