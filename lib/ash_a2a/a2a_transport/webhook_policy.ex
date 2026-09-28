defmodule AshA2A.A2ATransport.WebhookPolicy do
  @moduledoc """
  SSRF admission for A2A push-notification webhook URLs.

  A push-notification config names a URL this server will POST to on every
  task status transition. Without a gate that URL is a server-side request
  forgery primitive (cloud metadata at `169.254.169.254`, loopback admin
  ports, RFC 1918 hosts behind the firewall). `admit/2` is that gate and it
  fails closed:

    * scheme must be `https` (`http` only with `allow_http: true`);
    * the URL must carry a host and must not carry userinfo;
    * the host is resolved (A and AAAA) and **every** resolved address must be
      public: loopback, RFC 1918, CGNAT, link-local, multicast, reserved,
      unspecified, IPv6 ULA/link-local, IPv4-mapped/-compatible IPv6 forms of
      those, and IPv6 prefixes that tunnel or translate to an embedded IPv4
      target (NAT64, Teredo, 6to4) are refused, unless the address falls in an explicit `allow_cidrs` entry;
    * an unresolvable host is refused.

  The admitted result carries the resolved addresses so the delivery worker
  (`AshA2A.A2ATransport.PushDelivery`) can connect to exactly the address that
  was admitted (pinning), closing the DNS-rebinding window between admission
  and connect. Delivery re-admits on every attempt.

  Options: `:allow_http` (default `false`), `:allow_cidrs` (list of
  `"a.b.c.d/n"` or IPv6 CIDR strings, default `[]`), `:resolver` (a
  `(charlist, :inet | :inet6) -> {:ok, [ip]} | {:error, term}` function,
  default `:inet.getaddrs/2`).
  """

  import Bitwise

  @type refusal :: {:error, atom(), String.t()}
  @type admitted :: %{uri: URI.t(), addresses: [:inet.ip_address()]}

  @blocked_v4 [
    {{0, 0, 0, 0}, 8},
    {{10, 0, 0, 0}, 8},
    {{100, 64, 0, 0}, 10},
    {{127, 0, 0, 0}, 8},
    {{169, 254, 0, 0}, 16},
    {{172, 16, 0, 0}, 12},
    {{192, 0, 0, 0}, 24},
    {{192, 0, 2, 0}, 24},
    {{192, 168, 0, 0}, 16},
    {{198, 18, 0, 0}, 15},
    {{198, 51, 100, 0}, 24},
    {{203, 0, 113, 0}, 24},
    {{224, 0, 0, 0}, 4},
    {{240, 0, 0, 0}, 4}
  ]

  @blocked_v6 [
    {{0, 0, 0, 0, 0, 0, 0, 0}, 128},
    {{0, 0, 0, 0, 0, 0, 0, 1}, 128},
    # IPv4-compatible (deprecated) ::a.b.c.d -- embeds an IPv4 target.
    {{0, 0, 0, 0, 0, 0, 0, 0}, 96},
    {{0x64, 0xFF9B, 0, 0, 0, 0, 0, 0}, 96},
    # NAT64 local-use prefix (RFC 8215).
    {{0x64, 0xFF9B, 1, 0, 0, 0, 0, 0}, 48},
    # Teredo (2001::/32) and 6to4 (2002::/16) tunnel an embedded IPv4 target.
    {{0x2001, 0, 0, 0, 0, 0, 0, 0}, 32},
    {{0x2002, 0, 0, 0, 0, 0, 0, 0}, 16},
    {{0x100, 0, 0, 0, 0, 0, 0, 0}, 64},
    {{0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, 32},
    {{0xFC00, 0, 0, 0, 0, 0, 0, 0}, 7},
    {{0xFE80, 0, 0, 0, 0, 0, 0, 0}, 10},
    {{0xFF00, 0, 0, 0, 0, 0, 0, 0}, 8}
  ]

  @doc """
  Admits `url` as a webhook target or returns a typed refusal
  `{:error, code, detail}`.
  """
  @spec admit(String.t() | term(), keyword()) :: {:ok, admitted()} | refusal()
  def admit(url, opts \\ [])

  def admit(url, opts) when is_binary(url) do
    allow_http = Keyword.get(opts, :allow_http, false)

    with {:ok, uri} <- parse(url),
         :ok <- check_scheme(uri, allow_http),
         {:ok, allow} <- parse_cidrs(Keyword.get(opts, :allow_cidrs, [])),
         {:ok, addresses} <- resolve(uri.host, Keyword.get(opts, :resolver, &:inet.getaddrs/2)),
         :ok <- check_addresses(addresses, allow) do
      {:ok, %{uri: uri, addresses: addresses}}
    end
  end

  def admit(_url, _opts),
    do: {:error, :refused_webhook_malformed, "webhook url must be a string"}

  @doc "True when `ip` is a non-public (blocked) address."
  @spec blocked_address?(:inet.ip_address()) :: boolean()
  def blocked_address?({a, b, c, d} = ip)
      when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255,
      do: ip == {255, 255, 255, 255} or Enum.any?(@blocked_v4, &in_cidr?(ip, &1))

  def blocked_address?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}),
    do: blocked_address?({hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF})

  def blocked_address?({_, _, _, _, _, _, _, _} = ip),
    do: Enum.any?(@blocked_v6, &in_cidr?(ip, &1))

  # -- steps ---------------------------------------------------------------

  defp parse(url) do
    case URI.new(url) do
      {:ok, %URI{host: host} = uri} when is_binary(host) and host != "" ->
        if is_nil(uri.userinfo),
          do: {:ok, uri},
          else: {:error, :refused_webhook_malformed, "webhook url must not carry userinfo"}

      {:ok, _} ->
        {:error, :refused_webhook_malformed, "webhook url has no host"}

      {:error, part} ->
        {:error, :refused_webhook_malformed, "webhook url is not a valid URI at #{inspect(part)}"}
    end
  end

  defp check_scheme(%URI{scheme: "https"}, _), do: :ok
  defp check_scheme(%URI{scheme: "http"}, true), do: :ok

  defp check_scheme(%URI{scheme: scheme}, _),
    do: {:error, :refused_webhook_scheme, "webhook scheme #{inspect(scheme)} is not admitted"}

  defp resolve(host, resolver) do
    host = host |> String.trim_leading("[") |> String.trim_trailing("]")

    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} ->
        {:ok, [ip]}

      {:error, _} ->
        charlist = String.to_charlist(host)

        addrs =
          [:inet, :inet6]
          |> Enum.flat_map(fn family ->
            case resolver.(charlist, family) do
              {:ok, list} -> list
              {:error, _} -> []
            end
          end)
          |> Enum.uniq()

        if addrs == [],
          do:
            {:error, :refused_webhook_unresolvable,
             "webhook host #{inspect(host)} did not resolve"},
          else: {:ok, addrs}
    end
  end

  defp check_addresses(addresses, allow) do
    case Enum.find(
           addresses,
           &(blocked_address?(&1) and not Enum.any?(allow, fn c -> in_cidr?(&1, c) end))
         ) do
      nil ->
        :ok

      ip ->
        {:error, :refused_webhook_private_address,
         "webhook host resolves to non-public address #{:inet.ntoa(ip)}"}
    end
  end

  defp parse_cidrs(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn cidr, {:ok, acc} ->
      case parse_cidr(cidr) do
        {:ok, c} ->
          {:cont, {:ok, [c | acc]}}

        :error ->
          {:halt, {:error, :refused_webhook_malformed, "bad allow_cidrs entry #{inspect(cidr)}"}}
      end
    end)
  end

  defp parse_cidrs(other),
    do: {:error, :refused_webhook_malformed, "allow_cidrs must be a list, got #{inspect(other)}"}

  defp parse_cidr(cidr) when is_binary(cidr) do
    {addr, bits} =
      case String.split(cidr, "/", parts: 2) do
        [a, b] -> {a, Integer.parse(b)}
        [a] -> {a, :host}
      end

    with {:ok, ip} <- :inet.parse_address(String.to_charlist(addr)) do
      max = if tuple_size(ip) == 4, do: 32, else: 128

      case bits do
        :host -> {:ok, {ip, max}}
        {n, ""} when n >= 0 and n <= max -> {:ok, {ip, n}}
        _ -> :error
      end
    else
      _ -> :error
    end
  end

  defp parse_cidr(_), do: :error

  defp in_cidr?(ip, {net, bits}) when tuple_size(ip) == tuple_size(net) do
    width = if tuple_size(ip) == 4, do: 8, else: 16
    total = tuple_size(ip) * width
    shift = total - bits
    to_int(ip, width) >>> shift == to_int(net, width) >>> shift
  end

  defp in_cidr?(_ip, _cidr), do: false

  defp to_int(tuple, width),
    do: tuple |> Tuple.to_list() |> Enum.reduce(0, fn part, acc -> (acc <<< width) + part end)

  @doc false
  # S42 refusal totality: every typed refusal this module returns is classified.
  def __sa2a_refusal_codes__ do
    %{
      refused_webhook_malformed: :refused_structure,
      refused_webhook_scheme: :refused_bounds,
      refused_webhook_unresolvable: :refused_bounds,
      refused_webhook_private_address: :refused_authority
    }
  end
end
