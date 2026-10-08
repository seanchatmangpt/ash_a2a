# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.TransportPlugForceSslTest do
  @moduledoc """
  Prod hardening for the HTTP transport (sobelow Config.HTTPS): a
  `AshA2A.Transport.Plug` mount with `force_ssl: [rewrite_on:
  [:x_forwarded_proto]]` refuses plaintext-behind-proxy requests
  (`x-forwarded-proto: http`) with 400 + HSTS, and serves
  `strict-transport-security` on allowed requests too. Real `Plug.Test`
  conns, direct `call/2` invocation; no mocks.
  """

  use ExUnit.Case, async: true

  @force_ssl [rewrite_on: [:x_forwarded_proto], hsts: true, hsts_include_subdomains: true]

  defp mounted(opts \\ []) do
    AshA2A.Transport.Plug.init(Keyword.merge([agent: __MODULE__.NeverStartedAgent], opts))
  end

  test "init defaults :force_ssl to nil" do
    assert %{force_ssl: nil} = AshA2A.Transport.Plug.init(agent: Foo)
  end

  test "plaintext behind proxy is refused with 400 + HSTS" do
    opts = mounted(force_ssl: @force_ssl)

    conn =
      :get
      |> Plug.Test.conn("/.well-known/agent-card.json")
      |> Plug.Conn.put_req_header("x-forwarded-proto", "http")
      |> AshA2A.Transport.Plug.call(opts)

    assert conn.status == 400
    assert conn.halted
    assert Plug.Conn.get_resp_header(conn, "strict-transport-security") == [
             "max-age=63072000; includeSubDomains"
           ]
  end

  test "https-forwarded request passes through with HSTS" do
    opts = mounted(force_ssl: @force_ssl)
    conn = request("/no/such/path", opts, [{"x-forwarded-proto", "https"}])

    assert conn.status == 404
    assert Plug.Conn.get_resp_header(conn, "strict-transport-security") == [
             "max-age=63072000; includeSubDomains"
           ]
  end

  test "no x-forwarded-proto header passes through (direct TLS termination)" do
    opts = mounted(force_ssl: @force_ssl)
    conn = request("/no/such/path", opts, [])
    assert conn.status == 404
    assert Plug.Conn.get_resp_header(conn, "strict-transport-security") != []
  end

  test "direct mount without :force_ssl keeps legacy behavior (no HSTS)" do
    opts = mounted()
    conn = request("/no/such/path", opts, [{"x-forwarded-proto", "http"}])
    assert conn.status == 404
    assert Plug.Conn.get_resp_header(conn, "strict-transport-security") == []
  end

  test "hsts without include_subdomains omits the suffix" do
    opts = mounted(force_ssl: [rewrite_on: [:x_forwarded_proto]])
    conn = request("/no/such/path", opts, [{"x-forwarded-proto", "https"}])
    assert conn.status == 404
    assert Plug.Conn.get_resp_header(conn, "strict-transport-security") == ["max-age=63072000"]
  end

  defp request(path, opts, headers) do
    conn =
      :get
      |> Plug.Test.conn(path)
      |> then(fn c ->
        Enum.reduce(headers, c, fn {k, v}, acc -> Plug.Conn.put_req_header(acc, k, v) end)
      end)

    AshA2A.Transport.Plug.call(conn, opts)
  end
end
