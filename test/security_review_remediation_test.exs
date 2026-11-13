# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SecurityReviewRemediationTest do
  use ExUnit.Case, async: true

  alias AshA2A.Protocol.PushNotificationSender.HTTP, as: PushHTTP
  alias AshA2A.Protocol.Version

  describe "A2A-Version echo" do
    test "hostile values never reach a response header verbatim" do
      assert Version.safe_echo("x\r\nSet-Cookie: a") == "invalid"
      assert Version.safe_echo(String.duplicate("9", 500)) == "invalid"
      assert Version.safe_echo("2.0") == "2.0"
    end

    test "lenient suffixes are not normalized into a supported version" do
      assert Version.normalize("1.1;x") == "1.1;x"
      assert Version.normalize("1.0-evil") == "1.0-evil"
      assert Version.normalize("1.1.3") == "1.1"
    end
  end

  describe "legacy push sender SSRF" do
    defp config(url), do: %{url: url, token: nil, authentication: nil}

    test "IPv4-mapped IPv6 loopback is refused" do
      assert {:error, {:private_host, _}} =
               PushHTTP.deliver(config("https://[::ffff:127.0.0.1]/hook"), %{"t" => 1})
    end

    test "CGNAT and metadata-adjacent literals are refused" do
      for host <- ["100.64.0.1", "0.0.0.0", "169.254.169.254"] do
        assert {:error, {:private_host, _}} =
                 PushHTTP.deliver(config("https://#{host}/hook"), %{"t" => 1}),
               host
      end
    end

    test "a redirect is reported, never followed" do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listener)

      server =
        Task.async(fn ->
          {:ok, sock} = :gen_tcp.accept(listener, 5_000)
          {:ok, _req} = :gen_tcp.recv(sock, 0, 5_000)

          :ok =
            :gen_tcp.send(
              sock,
              "HTTP/1.1 302 Found\r\nlocation: http://169.254.169.254/\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
            )

          :gen_tcp.close(sock)
        end)

      assert {:error, {:http_status, 302}} =
               PushHTTP.deliver(
                 config("http://127.0.0.1:#{port}/hook"),
                 %{"t" => 1},
                 block_private_ips: false,
                 require_https: false,
                 attempts: 1
               )

      Task.await(server, 5_000)
      :gen_tcp.close(listener)
    end
  end
end

defmodule AshA2A.Protocol.JSONGuardTest do
  use ExUnit.Case, async: true
  alias AshA2A.Protocol.JSONGuard

  test "deep nesting is refused, normal bodies decode" do
    assert {:error, {:nesting_exceeded, 64}} = JSONGuard.decode(String.duplicate("[", 100_000))
    assert {:ok, %{"a" => [1, %{"b" => 2}]}} = JSONGuard.decode(~s({"a":[1,{"b":2}]}))
  end

  test "brackets inside strings do not count toward depth" do
    body = Jason.encode!(%{"s" => String.duplicate("[", 500) <> "\\\"["})
    assert {:ok, _} = JSONGuard.decode(body, 4)
  end
end
