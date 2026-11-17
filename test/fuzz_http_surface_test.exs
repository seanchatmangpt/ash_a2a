# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.FuzzHttpSurfaceTest do
  # Seeded fuzz of the REAL plugs with Plug.Test: JSON-RPC batch/envelope handling and
  # the HTTP+JSON path/query parser. Properties for client-controlled input: never a
  # raise, never a 5xx, always a well-formed A2A error body, and no stack trace or
  # internal detail in any body.
  use ExUnit.Case, async: true

  alias AshA2A.FuzzGen
  alias AshA2A.Test.PlugFixture.GreeterAgent

  @iterations FuzzGen.iterations(500)

  setup do
    agent = :"fuzz_http_agent_#{System.unique_integer([:positive])}"
    {:ok, pid} = GreeterAgent.start_link(name: agent)
    on_exit(fn -> AshA2A.TestSupport.SafeStop.stop(pid) end)
    %{agent: agent}
  end

  @leaks [
    "** (",
    "stacktrace",
    "Stacktrace",
    "(FunctionClauseError",
    "FunctionClauseError",
    "ArgumentError",
    "MatchError",
    "BadMapError",
    "KeyError",
    "Protocol.UndefinedError",
    "UndefinedFunctionError",
    "CaseClauseError",
    "lib/ash_a2a",
    "/home/",
    ".ex:",
    "Elixir.",
    "#PID<",
    "#Reference<",
    "%AshA2A",
    "(ash_a2a ",
    "(elixir ",
    "(plug ",
    "(jason "
  ]

  defp assert_clean(body, ctx) do
    for leak <- @leaks do
      refute String.contains?(body, leak),
             "body leaks #{inspect(leak)} for #{ctx}: #{String.slice(body, 0, 300)}"
    end
  end

  defp call(mod, opts, method, path, body \\ nil, headers \\ []) do
    conn =
      Plug.Test.conn(method, path, body)
      |> Plug.Conn.put_req_header("a2a-version", "1.1")

    conn = Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)
    mod.call(conn, opts)
  end

  defp guarded(fun, ctx) do
    case FuzzGen.run_with_deadline(fun, 15_000) do
      {:ok, conn} -> conn
      other -> flunk("#{ctx}: raised or hung: #{inspect(other, limit: 8, printable_limit: 200)}")
    end
  end

  # ---- HTTP+JSON path / query ----------------------------------------------------

  @segments [
    "message:send",
    "message:stream",
    "message:send:send",
    "message%3Asend",
    "message%3asend",
    "message:sendx",
    "message:sen",
    "xmessage:send",
    "message:",
    ":send",
    "message",
    "tasks",
    "tasks:send",
    "tasks:cancel",
    ":cancel",
    ":subscribe",
    "t1",
    "t1:cancel",
    "t1:subscribe",
    "t1%3Acancel",
    "t1:cancel:cancel",
    "t1:cancelx",
    "t1:Cancel",
    "t%2F1:cancel",
    "t%252F1",
    "..",
    "%2e%2e",
    ".",
    "",
    "%00",
    "%",
    "%G0",
    "%ZZ",
    "%C0%AF",
    "%FF",
    "%E2%82",
    "pushNotificationConfig",
    "pushNotificationConfigs",
    "agent",
    "extendedAgentCard",
    ".well-known",
    "agent-card.json",
    "v1",
    "{id}",
    "*",
    "?",
    "#",
    "é",
    "日本語",
    "%E6%97%A5",
    "%E2%80%AE",
    "a b",
    "a%20b",
    "a+b"
  ]

  defp random_path do
    n = FuzzGen.int(5)
    segs = for _ <- 1..n//1, do: segment()
    "/" <> Enum.join(segs, "/") <> FuzzGen.pick(["", "", "/", "//", "/."])
  end

  defp segment do
    case FuzzGen.int(8) do
      0 -> FuzzGen.pick(@segments) <> FuzzGen.pick(@segments)
      1 -> String.duplicate("a", 1 + FuzzGen.int(5_000))
      2 -> percent(FuzzGen.random_bytes(1 + FuzzGen.int(6)))
      _ -> FuzzGen.pick(@segments)
    end
  end

  defp percent(bytes), do: for(<<b <- bytes>>, into: "", do: "%" <> Base.encode16(<<b>>))

  @query_pairs [
    "pageSize=1",
    "pageSize=1&pageSize=2",
    "pageSize=abc",
    "pageSize=-5",
    "pageSize=99999999999999999999",
    "pageSize[]=1",
    "pageSize[a]=1",
    "pageSize[a][b]=1",
    "pageToken=",
    "pageToken=%",
    "pageToken=%FF%FE",
    "pageToken=" <> String.duplicate("A", 5_000),
    "status=TASK_STATE_WORKING&status=TASK_STATE_COMPLETED",
    "status[]=x",
    "status=%00",
    "contextId=a&contextId=b",
    "contextId[]=a",
    "historyLength=-1",
    "historyLength=1.5",
    "historyLength=1e999",
    "includeArtifacts=maybe",
    "includeArtifacts=true&includeArtifacts=false",
    "lastSeenGeneration=1&lastSeenGeneration=x",
    "lastSeenGeneration=%",
    "lastSeenGeneration=99999999999999999999999",
    "statusTimestampAfter=nope",
    "statusTimestampAfter=2026-01-01T00:00:00Z&statusTimestampAfter=x",
    "a=%",
    "=",
    "&&&",
    "==",
    "a",
    "%ZZ=1",
    "%=1",
    "k=%E2%82",
    "tenant=%2F",
    "%E2%80%AE=1",
    "a=" <> String.duplicate("b", 20_000)
  ]

  defp random_query do
    case FuzzGen.int(5) do
      0 ->
        ""

      1 ->
        "?" <> FuzzGen.pick(@query_pairs)

      _ ->
        "?" <> Enum.join(for(_ <- 1..(1 + FuzzGen.int(4)), do: FuzzGen.pick(@query_pairs)), "&")
    end
  end

  @methods [:get, :post, :put, :delete, :patch, :options, :head]

  test "HTTP+JSON: hostile paths, methods and query strings are never 5xx and never leak",
       %{agent: agent} do
    FuzzGen.seed(2001)
    mod = AshA2A.Transport.HTTPJSON
    opts = mod.init(agent: agent, base_url: "http://x/rest")

    for i <- 1..@iterations do
      method = FuzzGen.pick(@methods)
      target = random_path() <> random_query()

      body =
        if method in [:post, :put, :patch],
          do: FuzzGen.pick(["", "{}", "[]", "null", "\"s\"", "{\"message\":1}", "{"]),
          else: nil

      ctx =
        "iteration #{i} #{method} #{inspect(target, limit: 200, printable_limit: 200)} body=#{inspect(body)}"

      conn =
        guarded(
          fn ->
            call(mod, opts, method, target, body, [{"content-type", "application/json"}])
          end,
          ctx
        )

      assert conn.status < 500,
             "#{ctx}: #{conn.status} #{String.slice(conn.resp_body || "", 0, 300)}"

      assert_clean(conn.resp_body || "", ctx)

      if conn.status >= 400 and method != :head and conn.resp_body not in [nil, ""] do
        assert {:ok, %{"error" => %{} = err}} = Jason.decode(conn.resp_body),
               "#{ctx}: #{conn.resp_body}"

        assert is_binary(err["message"]) or is_binary(err["status"]), ctx
      end
    end
  end

  test "HTTP+JSON: percent-encoding and suffix confusion resolve like the literal route", %{
    agent: agent
  } do
    mod = AshA2A.Transport.HTTPJSON
    opts = mod.init(agent: agent, base_url: "http://x/rest")

    body =
      Jason.encode!(%{
        "message" => %{"messageId" => "m", "role" => "ROLE_USER", "parts" => [%{"text" => "hi"}]}
      })

    ok = call(mod, opts, :post, "/message:send", body, [{"content-type", "application/json"}])
    assert ok.status == 200

    for path <- [
          "/message:sendx",
          "/message:send:send",
          "/xmessage:send",
          "/message:",
          "/message%3Asendx",
          "/message:send/x",
          "/%252Fmessage:send"
        ] do
      conn = call(mod, opts, :post, path, body, [{"content-type", "application/json"}])
      assert conn.status in [400, 404, 405], "#{path}: #{conn.status}"
      assert_clean(conn.resp_body, path)
    end

    # a double-encoded slash is one segment, never a path traversal into another route
    conn = call(mod, opts, :get, "/tasks/a%252Fb")
    assert conn.status in [400, 404]
    conn = call(mod, opts, :get, "/tasks/a%2Fb")
    assert conn.status in [400, 404]
    conn = call(mod, opts, :get, "/tasks/%E6%97%A5%E6%9C%AC")
    assert conn.status in [400, 404]
  end

  # ---- JSON-RPC batch and envelope ----------------------------------------------

  defp rpc_item do
    case FuzzGen.int(8) do
      0 ->
        %{
          "jsonrpc" => "2.0",
          "id" => FuzzGen.scalar(),
          "method" => "tasks/get",
          "params" => %{"id" => FuzzGen.evil_string()}
        }

      1 ->
        %{"jsonrpc" => "2.0", "method" => "tasks/get", "params" => %{"id" => "x"}}

      2 ->
        %{"jsonrpc" => "2.0", "id" => 1, "method" => FuzzGen.scalar()}

      3 ->
        %{"jsonrpc" => FuzzGen.scalar(), "id" => 1, "method" => "message/send"}

      4 ->
        %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "message/send",
          "params" => FuzzGen.wrong_value()
        }

      5 ->
        FuzzGen.json_safe(FuzzGen.term(3, 3))

      6 ->
        %{"jsonrpc" => "2.0", "id" => 1, "method" => "agent/getAuthenticatedExtendedCard"}

      7 ->
        %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tasks/list",
          "params" => FuzzGen.pick([%{}, %{"pageSize" => FuzzGen.number()}, []])
        }
    end
  end

  defp enc(term), do: Jason.encode!(FuzzGen.json_safe(term))

  defp rpc_body do
    case FuzzGen.int(6) do
      0 ->
        enc([])

      1 ->
        enc(for(_ <- 1..(1 + FuzzGen.int(30)), do: rpc_item()))

      2 ->
        enc(rpc_item())

      3 ->
        enc([rpc_item(), 1, nil, "x", []])

      4 ->
        FuzzGen.raw_body()

      5 ->
        enc(
          for(
            _ <- 1..300,
            do: %{
              "jsonrpc" => "2.0",
              "id" => 1,
              "method" => "tasks/get",
              "params" => %{"id" => "x"}
            }
          )
        )
    end
  end

  defp well_formed_rpc?(%{"jsonrpc" => "2.0", "error" => %{"code" => c, "message" => m}})
       when is_integer(c) and is_binary(m), do: true

  defp well_formed_rpc?(%{"jsonrpc" => "2.0", "result" => _}), do: true

  defp well_formed_rpc?(list) when is_list(list) and list != [],
    do: Enum.all?(list, &well_formed_rpc?/1)

  defp well_formed_rpc?(_), do: false

  for {label, mod, extra} <- [
        {"Protocol.Plug", AshA2A.Protocol.Plug, [json_rpc_path: []]},
        {"Transport.Plug", AshA2A.Transport.Plug, [json_rpc_path: []]},
        {"A2ATransport.Plug", AshA2A.A2ATransport.Plug, [json_rpc_path: []]}
      ] do
    test "#{label}: batch and hostile JSON-RPC bodies answer 200 with well-formed JSON-RPC errors",
         %{agent: agent} do
      FuzzGen.seed(2002)
      mod = unquote(mod)
      opts = mod.init([agent: agent, base_url: "http://x/a2a"] ++ unquote(extra))

      for i <- 1..div(@iterations, 2) do
        body = rpc_body()

        ctx =
          "#{unquote(label)} iteration #{i} body=#{inspect(body, limit: 80, printable_limit: 200)}"

        conn =
          guarded(
            fn -> call(mod, opts, :post, "/", body, [{"content-type", "application/json"}]) end,
            ctx
          )

        assert conn.status < 500, "#{ctx}: #{conn.status} #{String.slice(conn.resp_body, 0, 300)}"
        assert_clean(conn.resp_body, ctx)

        if conn.status == 200 do
          assert {:ok, decoded} = Jason.decode(conn.resp_body),
                 "#{ctx}: not JSON: #{conn.resp_body}"

          assert well_formed_rpc?(decoded), "#{ctx}: #{conn.resp_body}"
        else
          assert conn.status in [400, 401, 403, 404, 405, 406, 413, 415], "#{ctx}: #{conn.status}"
        end
      end
    end
  end
end
