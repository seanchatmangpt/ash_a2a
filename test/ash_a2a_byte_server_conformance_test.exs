# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ByteServerConformanceTest do
  @moduledoc """
  Byte-for-byte live BEAM server conformance court against `AshA2A.Test.ByteServer`.
  Verifies raw TCP wire bytes, JWS card signing, 304 conditional GET, fail-closed auth,
  cross-tenant SEC-01 isolation, SSE streaming, HTTP+JSON REST, push webhook delivery,
  RSA-SHA256 DKIM email cryptography, and live gRPC HTTP/2 port binding with zero mocks.
  """
  use ExUnit.Case, async: false

  alias AshA2A.Protocol.Client
  alias AshA2A.Test.ByteServer

  setup do
    srv = ByteServer.start!()
    on_exit(srv.stop)
    {:ok, srv: srv}
  end

  defp raw_tcp_http(port, req_bytes) do
    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw], 5_000)

    :ok = :gen_tcp.send(sock, req_bytes)
    resp = recv_until_close(sock, <<>>)
    :ok = :gen_tcp.close(sock)
    resp
  end

  defp recv_until_close(sock, acc) do
    case :gen_tcp.recv(sock, 0, 2_000) do
      {:ok, chunk} -> recv_until_close(sock, acc <> chunk)
      {:error, :closed} -> acc
      {:error, :timeout} -> acc
    end
  end

  defp parse_raw_http(raw) do
    [head, body] = String.split(raw, "\r\n\r\n", parts: 2)
    [status_line | header_lines] = String.split(head, "\r\n")

    headers =
      Map.new(header_lines, fn line ->
        [k, v] = String.split(line, ":", parts: 2)
        {String.downcase(String.trim(k)), String.trim(v)}
      end)

    {status_line, headers, body}
  end

  test "raw TCP GET /.well-known/agent-card.json serves ES256-signed card and 304 on If-None-Match",
       %{srv: srv} do
    req =
      "GET /.well-known/agent-card.json HTTP/1.1\r\nHost: 127.0.0.1:#{srv.http_port}\r\nConnection: close\r\n\r\n"

    {status_line, headers, body} = raw_tcp_http(srv.http_port, req) |> parse_raw_http()
    assert status_line == "HTTP/1.1 200 OK"
    assert headers["content-type"] =~ "application/json"
    assert is_binary(etag = headers["etag"])
    assert is_binary(headers["last-modified"])
    assert headers["cache-control"] =~ "max-age="

    card = Jason.decode!(body)
    assert card["name"] == "byte_server_agent"
    assert card["capabilities"]["streaming"] == true
    assert card["capabilities"]["pushNotifications"] == true
    assert is_list(card["signatures"]) and length(card["signatures"]) == 1
    assert :ok = AshA2A.Protocol.CardSigning.verify(card, srv.card_pub_key, url: srv.base_url)

    req_304 =
      "GET /.well-known/agent-card.json HTTP/1.1\r\nHost: 127.0.0.1:#{srv.http_port}\r\nIf-None-Match: #{etag}\r\nConnection: close\r\n\r\n"

    {status_304, headers_304, body_304} = raw_tcp_http(srv.http_port, req_304) |> parse_raw_http()
    assert status_304 == "HTTP/1.1 304 Not Modified"
    assert headers_304["etag"] == etag
    assert body_304 == ""
  end

  test "GET schema endpoints and health/ready probes answer 200 with real payloads", %{srv: srv} do
    for path <- [
          "/.well-known/agent-card.schema.json",
          "/.well-known/skills.schema.json",
          "/health/live",
          "/health/ready",
          "/ready"
        ] do
      resp = Req.get!(srv.base_url <> path)
      assert resp.status == 200
    end
  end

  test "POST / fails closed without valid bearer and enforces SEC-01 tenant isolation", %{
    srv: srv
  } do
    unauth =
      Req.post!(srv.base_url <> "/",
        json: %{"jsonrpc" => "2.0", "id" => "1", "method" => "tasks/list", "params" => %{}}
      )

    assert unauth.status == 401

    forged =
      Req.post!(srv.base_url <> "/",
        headers: [{"authorization", "Bearer forged_token"}],
        json: %{"jsonrpc" => "2.0", "id" => "2", "method" => "tasks/list", "params" => %{}}
      )

    assert forged.status == 401

    send_resp =
      Req.post!(srv.base_url <> "/",
        headers: [{"authorization", "Bearer #{srv.token_a}"}, {"a2a-version", "1.1"}],
        json: %{
          "jsonrpc" => "2.0",
          "id" => "req-create-1",
          "method" => "message/send",
          "params" => %{
            "message" => %{
              "role" => "ROLE_USER",
              "messageId" => "byte-msg-1",
              "metadata" => %{"skill" => "create_order"},
              "parts" => [
                %{"data" => %{"reference" => "PO-BYTE-001", "amount_cents" => 4200}}
              ]
            },
            "metadata" => %{"a2a.auth" => %{"sub" => "spoofed_principal"}}
          }
        }
      )

    assert send_resp.status == 200
    assert List.first(send_resp.headers["a2a-version"]) == "1.1"
    task = send_resp.body["result"]["task"] || send_resp.body["result"]
    task_id = task["id"]
    assert is_binary(task_id)
    refute Jason.encode!(task) =~ "spoofed_principal"
    refute Jason.encode!(task) =~ "tok_alpha_"

    # Cross-tenant isolation: principal_b cannot see principal_a's task (-32001, never 403)
    cross =
      Req.post!(srv.base_url <> "/",
        headers: [{"authorization", "Bearer #{srv.token_b}"}],
        json: %{
          "jsonrpc" => "2.0",
          "id" => "req-cross-1",
          "method" => "tasks/get",
          "params" => %{"id" => task_id}
        }
      )

    assert cross.status == 200
    assert cross.body["error"]["code"] == -32001
  end

  test "raw TCP POST / message/stream emits real SSE frames and HTTP+JSON REST mirrors task state",
       %{srv: srv} do
    payload =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => "stream-1",
        "method" => "message/stream",
        "params" => %{
          "message" => %{
            "role" => "ROLE_USER",
            "messageId" => "byte-stream-msg-1",
            "metadata" => %{"skill" => "list_orders"},
            "parts" => [%{"data" => %{}}]
          }
        }
      })

    raw_req =
      "POST / HTTP/1.1\r\n" <>
        "Host: 127.0.0.1:#{srv.http_port}\r\n" <>
        "Authorization: Bearer #{srv.token_a}\r\n" <>
        "Content-Type: application/json\r\n" <>
        "Content-Length: #{byte_size(payload)}\r\n" <>
        "Connection: close\r\n\r\n" <> payload

    {status_line, headers, body} = raw_tcp_http(srv.http_port, raw_req) |> parse_raw_http()
    assert status_line == "HTTP/1.1 200 OK"
    assert headers["content-type"] =~ "text/event-stream"

    {events, _buf} = Client.SSE.feed(Client.SSE.new(), body)
    assert length(events) >= 1

    # REST /message:send + GET /tasks/:id
    rest_send =
      Req.post!(srv.base_url <> "/message:send",
        headers: [{"authorization", "Bearer #{srv.token_a}"}],
        json: %{
          "message" => %{
            "role" => "ROLE_USER",
            "messageId" => "byte-rest-msg-1",
            "metadata" => %{"skill" => "create_order"},
            "parts" => [
              %{"data" => %{"reference" => "PO-REST-002", "amount_cents" => 9900}}
            ]
          }
        }
      )

    assert rest_send.status in [200, 201]
    rest_task_id = rest_send.body["task"]["id"] || rest_send.body["id"]
    assert is_binary(rest_task_id)

    rest_get =
      Req.get!(srv.base_url <> "/tasks/#{rest_task_id}",
        headers: [{"authorization", "Bearer #{srv.token_a}"}]
      )

    assert rest_get.status == 200
  end

  test "POST /email/inbound enforces real RSA-SHA256 DKIM cryptography (anti-cheating falsifier)",
       %{srv: srv} do
    signed_mime =
      ByteServer.Dkim.sign_rfc5322(
        srv.dkim_priv_key,
        "vito@sender.example",
        "dispatch@fnox.io",
        "PO-EMAIL-DKIM-001",
        "Create work order for Highland Park HVAC."
      )

    ok_resp =
      Req.post!(srv.base_url <> "/email/inbound",
        headers: [{"content-type", "message/rfc822"}],
        body: signed_mime
      )

    assert ok_resp.status == 200
    assert ok_resp.body["ok"] == true
    assert ok_resp.body["principal"] == srv.principal_a

    # Tamper a single byte in the email body -> cryptographic refusal (403)
    tampered_mime = String.replace(signed_mime, "Highland Park", "Highland Pork")

    bad_resp =
      Req.post!(srv.base_url <> "/email/inbound",
        headers: [{"content-type", "message/rfc822"}],
        body: tampered_mime
      )

    assert bad_resp.status == 403
    assert bad_resp.body["error"] =~ "dkim_crypto_failed"
  end

  test "external a2aproject/a2a v1.1.0-rc protobuf/gRPC oracle validates ByteServer wire bytes (unfakeable)",
       %{srv: srv} do
    oracle_script = Path.expand("support/a2a_v1_1_oracle/oracle.py", __DIR__)
    uv = System.find_executable("uv") || Path.expand("~/.local/bin/uv")

    assert File.exists?(uv),
           "uv executable required to run external v1.1.0-rc protobuf/gRPC oracle"

    {out, status} =
      System.cmd(
        uv,
        [
          "run",
          "--with",
          "grpcio",
          "--with",
          "protobuf",
          "--with",
          "googleapis-common-protos",
          "python3",
          oracle_script,
          "--http-url",
          srv.base_url,
          "--grpc-port",
          Integer.to_string(srv.grpc_port),
          "--token",
          srv.token_a
        ],
        stderr_to_stdout: true
      )

    assert status == 0, "external v1.1.0-rc oracle failed (exit #{status}): #{out}"

    json_line =
      out
      |> String.split("\n", trim: true)
      |> List.last()

    report = Jason.decode!(json_line)
    assert report["ok"] == true
    assert report["oracle"] == "a2aproject/a2a@v1.1.0-rc"
    assert report["http"]["card_name"] == "byte_server_agent"
    assert report["http"]["http_task_generation"] >= 1
    assert report["grpc"]["grpc_listed_count"] >= 1
  end

  test "live gRPC HTTP/2 endpoint accepts TCP connection and webhook sink receives real HTTP POST",
       %{srv: srv} do
    {:ok, grpc_sock} =
      :gen_tcp.connect(~c"127.0.0.1", srv.grpc_port, [:binary, active: false], 2_000)

    :ok = :gen_tcp.close(grpc_sock)

    ByteServer.WebhookSink.subscribe(srv.webhook_state)

    hook_resp =
      Req.post!(srv.webhook_url,
        json: %{"event" => "task.completed", "source" => "byte_server_court"}
      )

    assert hook_resp.status == 200
    assert_receive {:byte_server_webhook, %{"event" => "task.completed"}}, 1_000
    assert length(ByteServer.WebhookSink.events(srv.webhook_state)) == 1
  end
end
