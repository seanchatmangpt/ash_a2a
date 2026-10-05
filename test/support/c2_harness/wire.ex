# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule C2Harness.Wire do
  @moduledoc """
  Wire clients the attacker (control-plane node) uses: length-prefixed frames over a unix
  domain socket (actuator UDS, `packet: 4`; real AuthorityService and Keymaster, 4-byte
  big-endian length) and over mTLS. Every call returns `{:ok, decoded_json}` or
  `{:error, transport_reason}`; a transport failure is never interpreted as a refusal.
  """

  @doc "One request frame to the actuator UDS (`packet: 4` framing), returns decoded reply."
  @spec uds(Path.t(), iodata(), timeout()) :: {:ok, map() | binary()} | {:error, term()}
  def uds(path, payload, timeout \\ 15_000) do
    with {:ok, s} <-
           :gen_tcp.connect(
             {:local, String.to_charlist(path)},
             0,
             [:binary, packet: 4, active: false],
             5_000
           ) do
      try do
        with :ok <- :gen_tcp.send(s, payload),
             {:ok, reply} <- :gen_tcp.recv(s, 0, timeout) do
          decode(reply)
        end
      after
        :gen_tcp.close(s)
      end
    end
  end

  @doc "Same over an already-open framed socket (several frames on one connection)."
  def uds_open(path) do
    :gen_tcp.connect(
      {:local, String.to_charlist(path)},
      0,
      [:binary, packet: 4, active: false],
      5_000
    )
  end

  def uds_call(s, payload, timeout \\ 15_000) do
    with :ok <- :gen_tcp.send(s, payload), {:ok, reply} <- :gen_tcp.recv(s, 0, timeout) do
      decode(reply)
    end
  end

  @doc "Raw bytes (caller supplies any length prefix); returns whatever comes back."
  def uds_raw(path, bytes, timeout \\ 5_000) do
    with {:ok, s} <-
           :gen_tcp.connect(
             {:local, String.to_charlist(path)},
             0,
             [:binary, packet: :raw, active: false],
             5_000
           ) do
      try do
        _ = :gen_tcp.send(s, bytes)
        :gen_tcp.recv(s, 0, timeout)
      after
        :gen_tcp.close(s)
      end
    end
  end

  @doc "AuthorityService/Keymaster style: `<<len::32, json>>` request and response."
  @spec lp(Path.t(), term() | {:raw, binary()}, timeout()) :: {:ok, map()} | {:error, term()}
  def lp(path, term, timeout \\ 15_000) do
    body = if match?({:raw, _}, term), do: elem(term, 1), else: Jason.encode!(term)

    with {:ok, s} <-
           :gen_tcp.connect(
             {:local, String.to_charlist(path)},
             0,
             [:binary, packet: :raw, active: false],
             5_000
           ) do
      try do
        with :ok <- :gen_tcp.send(s, <<byte_size(body)::32, body::binary>>),
             {:ok, <<len::32>>} <- :gen_tcp.recv(s, 4, timeout),
             {:ok, resp} <- :gen_tcp.recv(s, len, timeout) do
          decode(resp)
        end
      after
        :gen_tcp.close(s)
      end
    end
  end

  @doc "Send declared length `len` with `body` (a lying prefix), read the framed reply."
  def lp_declared(path, len, body, timeout \\ 5_000) do
    with {:ok, s} <-
           :gen_tcp.connect(
             {:local, String.to_charlist(path)},
             0,
             [:binary, packet: :raw, active: false],
             5_000
           ) do
      try do
        _ = :gen_tcp.send(s, <<len::32, body::binary>>)

        with {:ok, <<l::32>>} <- :gen_tcp.recv(s, 4, timeout),
             {:ok, resp} <- :gen_tcp.recv(s, l, timeout) do
          decode(resp)
        end
      after
        :gen_tcp.close(s)
      end
    end
  end

  @doc """
  One frame over TLS 1.3 to the actuator's mTLS port. `ssl` are extra client options
  (`certfile`/`keyfile` of the credential to present). Returns `{:error, {:tls, why}}` when
  the handshake or the first exchange is refused by the peer.
  """
  def tls(port, payload, ssl \\ [], timeout \\ 10_000) do
    opts =
      [:binary, packet: 4, active: false, versions: [:"tlsv1.3"], verify: :verify_none] ++ ssl

    case :ssl.connect({127, 0, 0, 1}, port, opts, timeout) do
      {:ok, s} ->
        try do
          with :ok <- :ssl.send(s, payload),
               {:ok, reply} <- :ssl.recv(s, 0, timeout) do
            decode(reply)
          else
            {:error, why} -> {:error, {:tls, why}}
          end
        after
          :ssl.close(s)
        end

      {:error, why} ->
        {:error, {:tls, why}}
    end
  end

  @doc "Plaintext TCP to the TLS port (no handshake)."
  def plaintext_tcp(port, payload, timeout \\ 3_000) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, packet: :raw, active: false], 3_000) do
      {:ok, s} ->
        try do
          _ = :gen_tcp.send(s, payload)
          :gen_tcp.recv(s, 0, timeout)
        after
          :gen_tcp.close(s)
        end

      {:error, why} ->
        {:error, why}
    end
  end

  @doc "Actuator execute frame."
  def execute_frame(effect_bytes, cert_bytes) do
    Jason.encode!(%{
      "op" => "execute",
      "effect" => Base.url_encode64(effect_bytes, padding: false),
      "certificate" => Base.url_encode64(cert_bytes, padding: false)
    })
  end

  defp decode(reply) do
    case Jason.decode(reply) do
      {:ok, m} -> {:ok, m}
      _ -> {:ok, reply}
    end
  end
end
