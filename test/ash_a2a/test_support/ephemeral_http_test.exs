# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Test.EphemeralHttpTest do
  @moduledoc """
  Real coverage for `AshA2A.Test.EphemeralHttp` (TQ-07): many concurrent
  listeners get distinct, kernel-assigned, really-bound ports, and each one
  really serves HTTP on the port it reports. No test doubles.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Test.EphemeralHttp

  defmodule PingPlug do
    @moduledoc false
    import Plug.Conn
    def init(opts), do: opts
    def call(conn, _opts), do: send_resp(conn, 200, "pong")
  end

  test "20 concurrent listeners each get a distinct bound port that really serves HTTP" do
    servers = for _ <- 1..20, do: EphemeralHttp.start!(PingPlug)
    ports = Enum.map(servers, & &1.port)

    assert length(Enum.uniq(ports)) == 20
    assert Enum.all?(ports, &(&1 > 0))

    for %{base_url: base_url, port: port} <- servers do
      assert base_url == "http://127.0.0.1:#{port}"
      assert %Req.Response{status: 200, body: "pong"} = Req.get!(base_url, retry: false)
    end
  end

  test "a fixed port reused while its listener is live collides -- the failure start!/1 removes" do
    %{port: port} = EphemeralHttp.start!(PingPlug)
    Process.flag(:trap_exit, true)

    assert {:error, _} =
             Bandit.start_link(plug: PingPlug, port: port, ip: {127, 0, 0, 1})
  end
end
