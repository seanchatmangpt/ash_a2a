# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C2.L07Tls.Transport do
  @moduledoc """
  Connection setup shared by the framed control-plane clients: a unix socket (default) or
  mutual TLS.

  TLS is selected by `ctx.c2_tls`, a map with:

    * `:host` (string, required) and `:port` (integer, required)
    * `:server_name` (string, optional, defaults to `:host`): SNI and hostname check name
    * a pinned CA, one of `:cacerts` (list of DER binaries) or `:cacertfile` (path)
    * a client identity for mutual TLS, one of `:cert` + `:key` (DER, `{type, der}`) or
      `:certfile` + `:keyfile` (paths)

  Peer verification (`verify_peer`), the pinned CA and the client certificate are not
  optional and cannot be overridden. When `:c2_tls` is present the client never falls back to
  the unix socket: an incomplete configuration or a failed handshake is a refusal.
  """

  @type conn :: {:gen_tcp | :ssl, port() | term()}

  @doc """
  Opens a connection. `socket_path` is used only when `ctx` has no `:c2_tls`.
  `base_opts` are the framing options (`packet:`, `active: false`, `:binary`).
  Returns `{:ok, conn}` or `{:error, reason}`; reasons are `:c2_tls_config_invalid`,
  `:connect_failed` or `{:tls_refused, term}`.
  """
  @spec connect(String.t() | nil, map(), list(), timeout()) :: {:ok, conn()} | {:error, term()}
  def connect(socket_path, ctx, base_opts, timeout) do
    case Map.get(ctx, :c2_tls) do
      nil -> connect_uds(socket_path, base_opts, timeout)
      cfg -> connect_tls(cfg, base_opts, timeout)
    end
  end

  @doc false
  def send({:gen_tcp, s}, data), do: :gen_tcp.send(s, data)
  def send({:ssl, s}, data), do: :ssl.send(s, data)

  @doc false
  def recv({:gen_tcp, s}, len, timeout), do: :gen_tcp.recv(s, len, timeout)
  def recv({:ssl, s}, len, timeout), do: :ssl.recv(s, len, timeout)

  @doc false
  def close({:gen_tcp, s}), do: :gen_tcp.close(s)
  def close({:ssl, s}), do: :ssl.close(s)

  defp connect_uds(path, base_opts, timeout) when is_binary(path) do
    case :gen_tcp.connect({:local, String.to_charlist(path)}, 0, base_opts, timeout) do
      {:ok, s} -> {:ok, {:gen_tcp, s}}
      {:error, _} -> {:error, :connect_failed}
    end
  end

  defp connect_uds(_, _, _), do: {:error, :connect_failed}

  defp connect_tls(cfg, base_opts, timeout) do
    with {:ok, host, port, tls_opts} <- tls_options(cfg),
         {:ok, _} <- Application.ensure_all_started(:ssl),
         {:ok, s} <-
           :ssl.connect(String.to_charlist(host), port, tls_opts ++ base_opts, timeout) do
      {:ok, {:ssl, s}}
    else
      {:error, :c2_tls_config_invalid} = e -> e
      {:error, reason} -> {:error, {:tls_refused, reason}}
      _ -> {:error, {:tls_refused, :unknown}}
    end
  end

  defp tls_options(%{host: host, port: port} = cfg)
       when is_binary(host) and host != "" and is_integer(port) and port > 0 do
    sni = Map.get(cfg, :server_name, host)

    with true <- (is_binary(sni) and sni != "") or :invalid,
         {:ok, ca} <- ca_opts(cfg),
         {:ok, id} <- identity_opts(cfg) do
      opts =
        [
          verify: :verify_peer,
          versions: [:"tlsv1.3", :"tlsv1.2"],
          server_name_indication: String.to_charlist(sni),
          depth: 4
        ] ++ ca ++ id

      {:ok, host, port, opts}
    else
      _ -> {:error, :c2_tls_config_invalid}
    end
  end

  defp tls_options(_), do: {:error, :c2_tls_config_invalid}

  defp ca_opts(%{cacerts: [_ | _] = certs}) do
    if Enum.all?(certs, &is_binary/1), do: {:ok, [cacerts: certs]}, else: :invalid
  end

  defp ca_opts(%{cacertfile: f}) when is_binary(f) and f != "",
    do: {:ok, [cacertfile: String.to_charlist(f)]}

  defp ca_opts(_), do: :invalid

  defp identity_opts(%{cert: c, key: {t, k}}) when is_binary(c) and is_atom(t) and is_binary(k),
    do: {:ok, [cert: c, key: {t, k}]}

  defp identity_opts(%{certfile: c, keyfile: k})
       when is_binary(c) and c != "" and is_binary(k) and k != "",
       do: {:ok, [certfile: String.to_charlist(c), keyfile: String.to_charlist(k)]}

  defp identity_opts(_), do: :invalid
end
