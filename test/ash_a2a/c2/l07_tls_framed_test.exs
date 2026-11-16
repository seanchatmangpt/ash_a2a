# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C2.L07TlsFramedTest do
  # UNVERIFIED: written without an Elixir toolchain. Uses a real :ssl listener (no mocks).
  use ExUnit.Case, async: false

  alias AshA2A.C2.L07Tls.Transport

  @base [:binary, packet: 4, active: false]

  defp san(name),
    do: [{:Extension, {2, 5, 29, 17}, false, [{:dNSName, String.to_charlist(name)}]}]

  defp pki do
    :public_key.pkix_test_data(%{
      server_chain: %{root: [], intermediates: [], peer: [extensions: san("localhost")]},
      client_chain: %{root: [], intermediates: [], peer: []}
    })
  end

  # Mutual-TLS echo server that accepts one connection.
  defp start_server(%{server_config: sc}) do
    {:ok, _} = Application.ensure_all_started(:ssl)

    {:ok, l} =
      :ssl.listen(
        0,
        sc ++ [:binary, packet: 4, active: false, reuseaddr: true] ++
          [verify: :verify_peer, fail_if_no_peer_cert: true]
      )

    {:ok, {_, port}} = :ssl.sockname(l)

    pid =
      spawn_link(fn ->
        with {:ok, s} <- :ssl.transport_accept(l, 5_000),
             {:ok, s} <- :ssl.handshake(s, 5_000),
             {:ok, data} <- :ssl.recv(s, 0, 5_000) do
          :ssl.send(s, data)
          :ssl.close(s)
        end
      end)

    {port, pid}
  end

  defp cfg(port, client_config, ca_from) do
    %{
      host: "localhost",
      port: port,
      cacerts: Keyword.fetch!(ca_from, :cacerts),
      cert: Keyword.fetch!(client_config, :cert),
      key: Keyword.fetch!(client_config, :key)
    }
  end

  test "mutual TLS with the pinned CA round-trips a frame" do
    %{server_config: _, client_config: cc} = p = pki()
    {port, _} = start_server(p)

    assert {:ok, conn} = Transport.connect(nil, %{c2_tls: cfg(port, cc, cc)}, @base, 5_000)
    assert :ok = Transport.send(conn, "ping")
    assert {:ok, "ping"} = Transport.recv(conn, 0, 5_000)
    Transport.close(conn)
  end

  test "server certificate from an unpinned CA is refused" do
    %{server_config: _} = p = pki()
    %{client_config: other_cc} = pki()
    {port, _} = start_server(p)

    # Pinned CA belongs to a different PKI than the server's certificate.
    c = cfg(port, other_cc, other_cc)
    assert {:error, {:tls_refused, _}} = Transport.connect(nil, %{c2_tls: c}, @base, 5_000)
  end

  test "server name that does not match the certificate is refused" do
    %{client_config: cc} = p = pki()
    {port, _} = start_server(p)

    c = cfg(port, cc, cc) |> Map.put(:server_name, "evil.example")
    assert {:error, {:tls_refused, _}} = Transport.connect(nil, %{c2_tls: c}, @base, 5_000)
  end

  test "incomplete TLS config is refused and never downgrades to the unix socket" do
    %{client_config: cc} = pki()
    base = cfg(1, cc, cc)

    for broken <- [
          Map.delete(base, :cacerts),
          Map.delete(base, :cert),
          Map.delete(base, :key),
          Map.delete(base, :host),
          Map.put(base, :port, 0),
          %{}
        ] do
      # A reachable-looking UDS path is supplied; it must be ignored.
      assert {:error, :c2_tls_config_invalid} =
               Transport.connect("/tmp/does-not-matter.sock", %{c2_tls: broken}, @base, 1_000)
    end
  end

  test "without c2_tls the transport is the unix socket" do
    assert {:error, :connect_failed} =
             Transport.connect("/nonexistent/l07.sock", %{}, @base, 1_000)
  end
end
