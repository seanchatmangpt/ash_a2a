# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C2.ApproveClientTest do
  # The peer is a real unix-socket server speaking the listener's framing and approve-op field
  # contract, but it is a STAND-IN: `authority_service` is a separate release and is not a
  # dependency of this project, so the real `AuthorityService.Listener` is not started here.
  use ExUnit.Case, async: true

  alias AshA2A.C2.ApproveClient

  @approval %{"envelope" => %{"kid" => "k"}, "message" => "AAAA"}

  defp tmp_sock do
    Path.join(System.tmp_dir!(), "ac-#{System.unique_integer([:positive])}.sock")
  end

  # Accepts one connection, sends the decoded request to the test, answers per the listener's
  # contract: all five approve fields present -> ok, otherwise malformed_request.
  defp start_listener(path, reply_fun) do
    File.rm(path)

    {:ok, l} =
      :gen_tcp.listen(0, [:binary, {:ifaddr, {:local, String.to_charlist(path)}}, active: false])

    parent = self()

    spawn_link(fn ->
      {:ok, s} = :gen_tcp.accept(l, 5_000)
      {:ok, <<len::32>>} = :gen_tcp.recv(s, 4, 5_000)
      {:ok, body} = :gen_tcp.recv(s, len, 5_000)
      req = Jason.decode!(body)
      send(parent, {:request, req})
      out = Jason.encode!(reply_fun.(req))
      :gen_tcp.send(s, <<byte_size(out)::32, out::binary>>)
      :gen_tcp.close(s)
    end)

    on_exit(fn -> File.rm(path) end)
    :ok
  end

  defp contract_reply(%{
         "op" => "approve",
         "approver" => _,
         "effect_digest" => _,
         "generation" => _,
         "approval" => _
       }),
       do: %{"ok" => true}

  defp contract_reply(_),
    do: %{"ok" => false, "refusal" => "malformed_request", "detail" => []}

  test "submits the listener's approve frame over a unix socket" do
    path = tmp_sock()
    start_listener(path, &contract_reply/1)

    assert :ok =
             ApproveClient.submit(%{authority_socket: path}, "alice", "sha256:abc", 9, @approval)

    assert_receive {:request,
                    %{
                      "op" => "approve",
                      "approver" => "alice",
                      "effect_digest" => "sha256:abc",
                      "generation" => 9,
                      "approval" => @approval
                    }}
  end

  test "a service refusal is returned with its code" do
    path = tmp_sock()

    start_listener(path, fn _ ->
      %{"ok" => false, "refusal" => "duplicate_approval", "detail" => []}
    end)

    assert {:error, {:refused, "duplicate_approval"}} =
             ApproveClient.submit(%{authority_socket: path}, "alice", "sha256:abc", 9, @approval)
  end

  test "an unparseable or unexpected reply is a transport refusal, not success" do
    path = tmp_sock()
    start_listener(path, fn _ -> %{"hello" => "world"} end)

    assert {:error, :authority_transport_refused} =
             ApproveClient.submit(%{authority_socket: path}, "alice", "sha256:abc", 9, @approval)
  end

  test "missing endpoint, dead socket and bad arguments are refused" do
    assert {:error, {:missing_c2_endpoint, :authority_socket}} =
             ApproveClient.submit(%{}, "alice", "sha256:abc", 9, @approval)

    assert {:error, :authority_transport_refused} =
             ApproveClient.submit(
               %{authority_socket: "/nonexistent/ac.sock"},
               "alice",
               "sha256:abc",
               9,
               @approval
             )

    assert {:error, :malformed_request} =
             ApproveClient.submit(%{authority_socket: "x"}, "", "sha256:abc", 9, @approval)

    assert {:error, :malformed_request} =
             ApproveClient.submit(%{authority_socket: "x"}, "alice", "sha256:abc", -1, @approval)
  end

  test "with an incomplete :c2_tls the client never falls back to the unix socket" do
    path = tmp_sock()
    start_listener(path, &contract_reply/1)

    assert {:error, :authority_transport_refused} =
             ApproveClient.submit(
               %{authority_socket: path, c2_tls: %{host: "localhost", port: 1}},
               "alice",
               "sha256:abc",
               9,
               @approval
             )

    refute_receive {:request, _}, 200
  end
end
