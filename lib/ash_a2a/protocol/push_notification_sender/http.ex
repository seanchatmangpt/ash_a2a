if Code.ensure_loaded?(Req) do
  defmodule AshA2A.Protocol.PushNotificationSender.HTTP do
    @moduledoc """
    Default `AshA2A.Protocol.PushNotificationSender`, POSTing payloads with `Req`.

    Available only when the optional `:req` dependency is present, and used
    automatically when it is.

    ## Options

    - `:timeout` — per-attempt receive timeout in ms (default: `15_000`). The
      spec recommends 10-30s.
    - `:attempts` — total delivery attempts including the first
      (default: `3`). Retries back off exponentially from 200ms.
    - `:require_https` — reject `http://` webhook URLs (default: `true`).
    - `:block_private_ips` — reject loopback, link-local and RFC 1918 hosts
      (default: `true`).

    ## Opting out for local development

    Both hardening options are ON by default: an agent that accepts webhook
    URLs from untrusted callers must not become an SSRF or plaintext-credential
    channel by accident. The spec makes SSRF protection and HTTPS a SHOULD for
    the agent, not a MUST, and the defaults do break ordinary local
    development — a webhook receiver on `localhost` is how the A2A compliance
    suite itself tests delivery — so both are explicit opt-OUTs, intended to
    be set loudly at the construction site:

        # Development / compliance-suite receiver on localhost:
        MyAgent.start_link(
          push_sender: {AshA2A.Protocol.PushNotificationSender.HTTP,
                        require_https: false, block_private_ips: false}
        )
    """

    @behaviour AshA2A.Protocol.PushNotificationSender

    require Logger

    @default_timeout 15_000
    @default_attempts 3
    @base_backoff_ms 200

    @impl AshA2A.Protocol.PushNotificationSender
    def deliver(config, payload, opts \\ []) do
      with :ok <- validate_url(config.url, opts),
           :ok <- validate_auth(config) do
        attempts = Keyword.get(opts, :attempts, @default_attempts)
        post_with_retry(config, payload, opts, attempts, 1)
      end
    end

    # The configured credentials travel verbatim inside the `authorization`
    # request header. A credential carrying CR/LF/NUL is a header-injection /
    # request-smuggling vector (and would only crash the delivery process in
    # Mint anyway), so it is refused typed before any connection is opened.
    defp validate_auth(%{authentication: %{scheme: scheme, credentials: credentials}})
         when is_binary(scheme) and is_binary(credentials) do
      if safe_header_value?(scheme) and safe_header_value?(credentials),
        do: :ok,
        else: {:error, {:invalid_credentials, :control_characters}}
    end

    defp validate_auth(%{token: token}) when is_binary(token) do
      if safe_header_value?(token),
        do: :ok,
        else: {:error, {:invalid_credentials, :control_characters}}
    end

    defp validate_auth(_config), do: :ok

    defp safe_header_value?(value),
      do: value != "" and not String.contains?(value, ["\r", "\n", "\0"])

    defp post_with_retry(config, payload, opts, attempts, attempt) do
      case post(config, payload, opts) do
        :ok ->
          :ok

        {:error, reason} when attempt < attempts ->
          Logger.debug(
            "A2A push delivery attempt #{attempt}/#{attempts} failed: #{inspect(reason)}"
          )

          Process.sleep(@base_backoff_ms * 2 ** (attempt - 1))
          post_with_retry(config, payload, opts, attempts, attempt + 1)

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp post(config, payload, opts) do
      req_opts = [
        headers: headers(config),
        receive_timeout: Keyword.get(opts, :timeout, @default_timeout),
        json: payload,
        retry: false
      ]

      case Req.post(config.url, req_opts) do
        {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
        {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
        {:error, reason} -> {:error, reason}
      end
    end

    # The spec requires the configured credentials to travel as an
    # Authorization header; `token` is the v0.3 spelling of the same thing.
    defp headers(config) do
      case authorization(config) do
        nil -> []
        value -> [{"authorization", value}]
      end
    end

    defp authorization(%{authentication: %{scheme: scheme, credentials: credentials}})
         when is_binary(scheme) and is_binary(credentials) do
      "#{scheme} #{credentials}"
    end

    defp authorization(%{token: token}) when is_binary(token), do: "Bearer #{token}"
    defp authorization(_config), do: nil

    defp validate_url(url, opts) do
      uri = URI.parse(url)

      cond do
        # Only HTTP(S) delivery is defined; a caller-supplied config URL with
        # any other scheme (file://, ftp://, gopher://...) is refused before
        # Req ever sees it — unconditionally, dev-friendly defaults or not.
        uri.scheme not in ["http", "https"] ->
          {:error, {:unsupported_scheme, uri.scheme}}

        Keyword.get(opts, :require_https, true) and uri.scheme != "https" ->
          {:error, {:insecure_url, url}}

        Keyword.get(opts, :block_private_ips, true) and private_host?(uri.host) ->
          {:error, {:private_host, uri.host}}

        true ->
          :ok
      end
    end

    defp private_host?(nil), do: true
    defp private_host?("localhost"), do: true

    defp private_host?(host) do
      case :inet.parse_address(String.to_charlist(host)) do
        {:ok, {127, _, _, _}} -> true
        {:ok, {10, _, _, _}} -> true
        {:ok, {192, 168, _, _}} -> true
        {:ok, {169, 254, _, _}} -> true
        {:ok, {172, second, _, _}} when second >= 16 and second <= 31 -> true
        {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
        _ -> false
      end
    end
  end
end
