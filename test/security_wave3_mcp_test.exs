# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SecurityWave3McpTest do
  @moduledoc """
  Security wave 3: the simulation server and its MCP surface.

    * `a2a_raw_request` reaches only the sim's own listeners (no SSRF through
      the `path` argument, no free-form HTTP method)
    * the sim gRPC listener binds loopback only
    * the MCP Streamable HTTP transport refuses a foreign `Host` or `Origin`
      (DNS rebinding) and, when a token is configured, a missing or wrong one
    * the sim push receiver bounds what it keeps
  """

  use ExUnit.Case, async: false

  alias AshA2A.Sim.MCP.{HTTP, Tools}
  alias AshA2A.Sim.Server

  @moduletag capture_log: true
  @moduletag timeout: 120_000

  setup_all do
    {:ok, server} = Server.start_link()
    info = Server.info()
    on_exit(fn -> if Process.alive?(server), do: Server.stop(server) end)

    # One MCP listener for the module (its session table is a named process).
    {:ok, sup} = HTTP.start_link(info: info, port: 0, auth_token: "wave3-mcp-token")
    {:ok, info: info, port: HTTP.port(sup)}
  end

  # A victim listener on another loopback port that records every connection.
  defp victim do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    parent = self()

    spawn_link(fn ->
      case :gen_tcp.accept(listen, 3_000) do
        {:ok, socket} ->
          send(parent, :victim_reached)
          :gen_tcp.close(socket)

        _ ->
          :ok
      end
    end)

    port
  end

  describe "a2a_raw_request stays on the sim's own listeners" do
    test "a path that would turn the mount into userinfo is refused", %{info: info} do
      port = victim()
      ctx = %{info: info}

      for mount <- ["root", "a2a", "rest"],
          path <- ["@127.0.0.1:#{port}/x", "//127.0.0.1:#{port}"] do
        assert {:error, text} =
                 Tools.call(
                   "a2a_raw_request",
                   %{"binding" => "http_json", "mount" => mount, "path" => path},
                   ctx
                 )

        assert text =~ "path"
      end

      refute_receive :victim_reached, 500
    end

    test "a path with a line break or a gRPC path off the sim is refused", %{info: info} do
      ctx = %{info: info}

      assert {:error, _} =
               Tools.call(
                 "a2a_raw_request",
                 %{"binding" => "jsonrpc", "path" => "/x\r\nHost: evil"},
                 ctx
               )

      assert {:error, _} =
               Tools.call(
                 "a2a_raw_request",
                 %{"binding" => "grpc", "path" => "@evil.example/x"},
                 ctx
               )
    end

    test "the HTTP method is a closed set", %{info: info} do
      assert {:error, text} =
               Tools.call(
                 "a2a_raw_request",
                 %{"binding" => "http_json", "method" => "NOT-A-METHOD"},
                 %{info: info}
               )

      assert text =~ "method"
    end

    test "an ordinary probe still reaches the sim", %{info: info} do
      assert {:ok, answer} =
               Tools.call(
                 "a2a_raw_request",
                 %{
                   "binding" => "http_json",
                   "method" => "GET",
                   "path" => "/tasks",
                   "token" => "none"
                 },
                 %{info: info}
               )

      assert answer["status"] == 401
    end
  end

  describe "the sim listeners are loopback only" do
    test "the gRPC port does not answer on a non-loopback interface", %{info: info} do
      {:ok, ifaddrs} = :inet.getifaddrs()

      external =
        for {_name, opts} <- ifaddrs,
            {:addr, {a, _, _, _} = ip} <- opts,
            a != 127,
            do: ip

      for ip <- external, port <- [info.grpc_port, info.http_port, info.push_port] do
        assert {:error, _} = :gen_tcp.connect(ip, port, [:binary, active: false], 1_000)
      end
    end
  end

  describe "MCP Streamable HTTP" do
    @initialize Jason.encode!(%{
                  "jsonrpc" => "2.0",
                  "id" => 1,
                  "method" => "initialize",
                  "params" => %{
                    "protocolVersion" => "2025-06-18",
                    "capabilities" => %{},
                    "clientInfo" => %{"name" => "t", "version" => "1"}
                  }
                })

    defp raw_post(port, headers) do
      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])

      head =
        ["POST /mcp HTTP/1.1", "content-type: application/json", "accept: application/json"] ++
          headers ++ ["content-length: #{byte_size(@initialize)}", "connection: close"]

      :ok = :gen_tcp.send(socket, Enum.join(head, "\r\n") <> "\r\n\r\n" <> @initialize)
      reply = read_all(socket, "")
      :gen_tcp.close(socket)
      [status_line | _] = String.split(reply, "\r\n")
      status_line |> String.split(" ") |> Enum.at(1) |> String.to_integer()
    end

    defp read_all(socket, acc) do
      case :gen_tcp.recv(socket, 0, 3_000) do
        {:ok, data} -> read_all(socket, acc <> data)
        {:error, _} -> acc
      end
    end

    test "a foreign Host is refused 403 (DNS rebinding)", %{port: port} do
      assert 403 =
               raw_post(port, [
                 "host: rebind.evil.example",
                 "authorization: Bearer wave3-mcp-token"
               ])
    end

    test "a foreign Origin is refused 403", %{port: port} do
      assert 403 =
               raw_post(port, [
                 "host: 127.0.0.1:#{port}",
                 "origin: http://evil.example",
                 "authorization: Bearer wave3-mcp-token"
               ])
    end

    test "a missing or wrong token is refused 401", %{port: port} do
      assert 401 = raw_post(port, ["host: 127.0.0.1:#{port}"])

      assert 401 =
               raw_post(port, ["host: localhost:#{port}", "authorization: Bearer wrong-token"])
    end

    test "the right token on a loopback Host is admitted", %{port: port} do
      assert 200 =
               raw_post(port, [
                 "host: localhost:#{port}",
                 "origin: http://localhost:3000",
                 "authorization: Bearer wave3-mcp-token"
               ])
    end
  end

  describe "the sim push receiver" do
    test "keeps a bounded number of deliveries and refuses an oversized body", %{info: info} do
      AshA2A.Sim.PushReceiver.reset()
      url = "http://127.0.0.1:#{info.push_port}/hook"

      big = :binary.copy("a", 1_100_000)

      assert %Req.Response{status: 413} =
               Req.post!(url, body: big, retry: false, headers: [{"connection", "close"}])

      assert AshA2A.Sim.PushReceiver.deliveries() == []

      assert %Req.Response{status: 200} =
               Req.post!(url,
                 json: %{"ok" => true},
                 retry: false,
                 headers: [{"connection", "close"}]
               )

      assert [%{body: %{"ok" => true}}] = AshA2A.Sim.PushReceiver.deliveries()
    end
  end
end
