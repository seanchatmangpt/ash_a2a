# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Egress.EndpointPolicy do
  @moduledoc """
  Shared outbound-endpoint admission (CWE-918) for egress that is not a push
  webhook (OCEL forwarder, future exporters).

  Admission is delegated read-only to `AshA2A.A2ATransport.WebhookPolicy.admit/2`
  (https only, every resolved address public, no userinfo). `request_options/2`
  then returns Req options that pin the connection to the admitted IP (original
  hostname kept for SNI/cert verification and the `host` header) and disable
  redirects, mirroring `AshA2A.A2ATransport.PushDelivery`.

  Refusals are `{:error, code, detail}` with the WebhookPolicy codes; nothing
  connects before admission succeeds.
  """

  alias AshA2A.A2ATransport.WebhookPolicy

  @policy_keys [:allow_http, :allow_cidrs, :resolver]

  @type admitted :: %{uri: URI.t(), ip: :inet.ip_address(), userinfo: String.t() | nil}

  @spec admit(String.t() | term(), keyword()) ::
          {:ok, admitted()} | {:error, atom(), String.t()}
  def admit(url, opts \\ []) do
    {url, userinfo} = split_userinfo(url, Keyword.get(opts, :allow_userinfo, false))

    case WebhookPolicy.admit(url, Keyword.take(opts, @policy_keys)) do
      {:ok, %{uri: uri, addresses: [ip | _]}} -> {:ok, %{uri: uri, ip: ip, userinfo: userinfo}}
      {:error, _code, _detail} = refusal -> refusal
    end
  end

  # Option `:allow_userinfo` (default false): the credential is removed from the
  # URL before admission and re-sent as an HTTP Basic header, never as part of
  # the pinned URL.
  defp split_userinfo(url, true) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{userinfo: ui} = uri} when is_binary(ui) ->
        {URI.to_string(%{uri | userinfo: nil}), URI.decode(ui)}

      _ ->
        {url, nil}
    end
  end

  defp split_userinfo(url, _), do: {url, nil}

  @doc "Req options (url, headers, pinning, no redirects) for a POST to `path` under the admitted endpoint."
  @spec request_options(admitted(), String.t()) :: keyword()
  def request_options(%{uri: uri, ip: ip} = admitted, path) when is_binary(path) do
    base_path = String.trim_trailing(uri.path || "", "/")
    target = %{uri | host: ip_host(ip), path: base_path <> path}

    [
      url: URI.to_string(target),
      headers: [{"host", host_header(uri)} | basic_auth(admitted)],
      redirect: false,
      retry: false,
      connect_options: [hostname: uri.host]
    ]
  end

  defp basic_auth(%{userinfo: ui}) when is_binary(ui),
    do: [{"authorization", "Basic " <> Base.encode64(ui)}]

  defp basic_auth(_), do: []

  defp ip_host({_, _, _, _} = ip), do: ip |> :inet.ntoa() |> to_string()
  defp ip_host(ip), do: "[" <> (ip |> :inet.ntoa() |> to_string()) <> "]"

  defp host_header(%URI{host: host, port: port, scheme: scheme}) do
    if URI.default_port(scheme) == port, do: host, else: "#{host}:#{port}"
  end
end
