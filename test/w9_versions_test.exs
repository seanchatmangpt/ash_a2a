# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.W9VersionsTest do
  @moduledoc """
  W9 item 1: A2A-Version negotiation is configurable per plug (`:versions`)
  and v1.1 is supported by default. Real `Plug.Test` conns against the three
  HTTP JSON-RPC plugs fronting a real agent GenServer; no mocks.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Protocol.Version
  alias AshA2A.Test.PlugFixture.GreeterAgent

  setup do
    agent = :"w9_versions_agent_#{System.unique_integer([:positive])}"
    {:ok, pid} = GreeterAgent.start_link(name: agent)
    on_exit(fn -> AshA2A.TestSupport.SafeStop.stop(pid) end)
    %{agent: agent}
  end

  defp message do
    {:ok, encoded} = AshA2A.Protocol.JSON.encode(AshA2A.Protocol.Message.new_user("hi"))
    encoded
  end

  defp send_message(mod, opts, headers, query \\ "") do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "message/send",
        "params" => %{"message" => message()}
      })

    :post
    |> Plug.Test.conn("/" <> query, body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.merge_req_headers(headers)
    |> mod.call(opts)
  end

  defp plugs(agent, extra \\ []) do
    base = [agent: agent, base_url: "http://localhost:4000/a2a"] ++ extra

    [
      {"Protocol.Plug", AshA2A.Protocol.Plug, AshA2A.Protocol.Plug.init(base)},
      {"A2ATransport.Plug", AshA2A.A2ATransport.Plug, AshA2A.A2ATransport.Plug.init(base)},
      {"Transport.Plug", AshA2A.Transport.Plug, AshA2A.Transport.Plug.init(base)}
    ]
  end

  describe "Version" do
    test "v1.1 is supported by default and advertised as the protocol version" do
      assert Version.protocol_version() == "1.1"
      assert "1.1" in Version.supported_default()
      assert Version.supported_default() == ["0.3", "1.0", "1.1"]
      assert Version.validate("1.1", Version.supported_default()) == :ok
      assert Version.validate("1.2", Version.supported_default()) == {:error, "1.2"}
    end

    test "at_least?/2 compares Major.Minor and ignores the patch" do
      assert Version.at_least?("1.1", "1.1")
      assert Version.at_least?("1.1.4", "1.1")
      assert Version.at_least?("2.0", "1.1")
      refute Version.at_least?("1.0", "1.1")
      refute Version.at_least?("1.0.9", "1.1")
      refute Version.at_least?("0.3", "1.1")
      refute Version.at_least?("garbage", "1.1")
      refute Version.at_least?(nil, "1.1")
    end

    test "negotiated_version/1 normalizes header values and defaults to 0.3" do
      assert Version.negotiated_version(["1.1.2"]) == "1.1"
      assert Version.negotiated_version("1.0") == "1.0"
      assert Version.negotiated_version([]) == "0.3"
      assert Version.negotiated_version(nil) == "0.3"
    end

    test "negotiated_version/1 on a conn: header wins, else the A2A-Version query parameter" do
      header = Plug.Test.conn(:get, "/") |> Plug.Conn.put_req_header("a2a-version", "1.1")
      assert Version.negotiated_version(header) == "1.1"

      query = Plug.Test.conn(:get, "/?A2A-Version=1.0")
      assert Version.negotiated_version(query) == "1.0"

      both =
        Plug.Test.conn(:get, "/?A2A-Version=1.0")
        |> Plug.Conn.put_req_header("a2a-version", "1.1")

      assert Version.negotiated_version(both) == "1.1"

      assert Version.negotiated_version(Plug.Test.conn(:get, "/")) == "0.3"
    end
  end

  describe "every plug" do
    test "accepts 0.3 (missing header), 1.0 and 1.1 by default and refuses 1.2 with -32009",
         %{agent: agent} do
      for {label, mod, opts} <- plugs(agent) do
        for {headers, expected_echo} <- [
              {[], "0.3"},
              {[{"a2a-version", "1.0"}], "1.0"},
              {[{"a2a-version", "1.1"}], "1.1"},
              {[{"a2a-version", "1.1.3"}], "1.1"}
            ] do
          conn = send_message(mod, opts, headers)
          body = Jason.decode!(conn.resp_body)

          assert %{"result" => _} = body, "#{label} #{inspect(headers)}: #{inspect(body)}"
          assert Plug.Conn.get_resp_header(conn, "a2a-version") == [expected_echo]
        end

        conn = send_message(mod, opts, [{"a2a-version", "1.2"}])
        assert %{"error" => %{"code" => -32_009}} = Jason.decode!(conn.resp_body)
        assert Plug.Conn.get_resp_header(conn, "a2a-version") == ["1.2"]
      end
    end

    test "honors the A2A-Version query parameter when the header is absent", %{agent: agent} do
      for {label, mod, opts} <- plugs(agent) do
        ok = send_message(mod, opts, [], "?A2A-Version=1.1")
        assert %{"result" => _} = Jason.decode!(ok.resp_body), label
        assert Plug.Conn.get_resp_header(ok, "a2a-version") == ["1.1"]

        bad = send_message(mod, opts, [], "?A2A-Version=7.7")
        assert %{"error" => %{"code" => -32_009}} = Jason.decode!(bad.resp_body), label
      end
    end

    test ":versions narrows the accepted set (default unchanged elsewhere)", %{agent: agent} do
      for {label, mod, opts} <- plugs(agent, versions: ["1.1"]) do
        assert %{"result" => _} =
                 mod
                 |> send_message(opts, [{"a2a-version", "1.1"}])
                 |> Map.fetch!(:resp_body)
                 |> Jason.decode!(),
               label

        for refused <- ["0.3", "1.0"] do
          conn = send_message(mod, opts, [{"a2a-version", refused}])

          assert %{"error" => %{"code" => -32_009}} = Jason.decode!(conn.resp_body),
                 "#{label}: #{refused} must be refused when :versions is [\"1.1\"]"
        end
      end
    end

    test ":versions can widen the set beyond the default", %{agent: agent} do
      for {label, mod, opts} <- plugs(agent, versions: Version.supported_default() ++ ["1.2"]) do
        conn = send_message(mod, opts, [{"a2a-version", "1.2"}])
        assert %{"result" => _} = Jason.decode!(conn.resp_body), label
      end
    end
  end

  describe "negotiated version reaches downstream code" do
    test "Protocol.Plug records it at conn.private[:a2a][:version]", %{agent: agent} do
      opts = AshA2A.Protocol.Plug.init(agent: agent, base_url: "http://localhost:4000/a2a")
      conn = send_message(AshA2A.Protocol.Plug, opts, [{"a2a-version", "1.1"}])
      assert Version.get_negotiated(conn) == "1.1"
      assert Version.at_least?(Version.get_negotiated(conn), "1.1")

      old = send_message(AshA2A.Protocol.Plug, opts, [{"a2a-version", "1.0"}])
      assert Version.get_negotiated(old) == "1.0"
      refute Version.at_least?(Version.get_negotiated(old), "1.1")
    end

    test "Transport.Plug records it at conn.private[:a2a][:version]", %{agent: agent} do
      opts = AshA2A.Transport.Plug.init(agent: agent, base_url: "http://localhost:4000/a2a")
      conn = send_message(AshA2A.Transport.Plug, opts, [{"a2a-version", "1.1"}])
      assert Version.get_negotiated(conn) == "1.1"
    end

    test "A2ATransport.Plug records it on locally-gated methods", %{agent: agent} do
      opts = AshA2A.A2ATransport.Plug.init(agent: agent, base_url: "http://localhost:4000/a2a")

      body =
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tasks/list", "params" => %{}})

      conn =
        :post
        |> Plug.Test.conn("/", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("a2a-version", "1.1")
        |> AshA2A.A2ATransport.Plug.call(opts)

      assert Version.get_negotiated(conn) == "1.1"
    end
  end

  describe "agent card" do
    test "advertises protocolVersion 1.1 on supportedInterfaces", %{agent: agent} do
      opts = AshA2A.Protocol.Plug.init(agent: agent, base_url: "http://localhost:4000/a2a")

      card =
        :get
        |> Plug.Test.conn("/.well-known/agent-card.json")
        |> AshA2A.Protocol.Plug.call(opts)
        |> Map.fetch!(:resp_body)
        |> Jason.decode!()

      assert [_ | _] = interfaces = card["supportedInterfaces"]
      assert Enum.all?(interfaces, &(&1["protocolVersion"] == "1.1"))
    end
  end
end
