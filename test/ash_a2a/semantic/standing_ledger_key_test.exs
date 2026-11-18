# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.StandingLedgerKeyTest do
  @moduledoc """
  DEP-04: the standing-ledger sealing key must be configurable so a chain
  sealed on one node verifies on every other node and after a restart.

  Chicago style: the real `AshA2A.Semantic.Standing.transition/3`, a real
  second BEAM node started with OTP's `:peer`, and the real `:persistent_term`
  slot the per-runtime fallback key lives in. `async: false` because the
  tests mutate `:ash_a2a` application env and the node-wide persistent term.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Semantic.{Envelope, Refusal, Standing}

  @ledger_key_term {Standing, :ledger_key}
  @received %{transport: "a2a/https", received_at: "2026-09-27T00:00:00Z"}
  @parsed %{media_type: "text/turtle", triple_count: 3}

  setup do
    previous_config = Application.get_env(:ash_a2a, :standing_ledger_key)
    previous_term = :persistent_term.get(@ledger_key_term, nil)

    on_exit(fn ->
      restore_env(previous_config)

      if previous_term,
        do: :persistent_term.put(@ledger_key_term, previous_term),
        else: :persistent_term.erase(@ledger_key_term)
    end)

    :ok
  end

  defp restore_env(nil), do: Application.delete_env(:ash_a2a, :standing_ledger_key)
  defp restore_env(value), do: Application.put_env(:ash_a2a, :standing_ledger_key, value)

  defp candidate(id) do
    {:ok, envelope} = Envelope.new(%{envelope_id: id, kind: "sa2a:Request"})
    envelope
  end

  # Simulates a node restart / a different node: the per-runtime random key is
  # replaced by a fresh, unrelated one, exactly what a new BEAM would generate.
  defp rotate_runtime_key! do
    :persistent_term.put(@ledger_key_term, :crypto.strong_rand_bytes(32))
  end

  test "a configured key survives a runtime-key rotation (restart / rolling update)" do
    Application.put_env(:ash_a2a, :standing_ledger_key, :crypto.strong_rand_bytes(32))

    {:ok, received} =
      Standing.transition(candidate("urn:uuid:dep04-restart"), :received, @received)

    rotate_runtime_key!()

    assert {:ok, %Envelope{standing: :parsed}} = Standing.transition(received, :parsed, @parsed)
  end

  test "without a configured key the chain is node-local: a rotated runtime key refuses it" do
    Application.delete_env(:ash_a2a, :standing_ledger_key)

    {:ok, received} = Standing.transition(candidate("urn:uuid:dep04-local"), :received, @received)
    rotate_runtime_key!()

    assert {:error, %Refusal{code: :standing_ledger_unsealed}} =
             Standing.transition(received, :parsed, @parsed)
  end

  test "a malformed configured key fails closed at boot and on transition" do
    for bad <- [:crypto.strong_rand_bytes(16), :crypto.strong_rand_bytes(33), "", :not_a_key] do
      Application.put_env(:ash_a2a, :standing_ledger_key, bad)

      assert_raise ArgumentError, ~r/standing_ledger_key must be exactly 32 raw bytes/, fn ->
        Standing.ensure_ledger_key()
      end

      assert_raise ArgumentError, fn ->
        Standing.transition(candidate("urn:uuid:dep04-bad"), :received, @received)
      end
    end
  end

  describe "across two real BEAM nodes" do
    setup do
      System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)

      unless Node.alive?() do
        {:ok, _} =
          Node.start(:"standing_key_primary_#{System.unique_integer([:positive])}", :shortnames)
      end

      host = Node.self() |> Atom.to_string() |> String.split("@") |> List.last()

      {:ok, peer_pid, peer_node} =
        :peer.start_link(%{
          name: :"standing_key_peer_#{System.unique_integer([:positive])}",
          host: String.to_charlist(host),
          args: [~c"-setcookie", Atom.to_charlist(Node.get_cookie())]
        })

      :ok = :rpc.call(peer_node, :code, :add_pathsz, [:code.get_path()])

      on_exit(fn ->
        try do
          :peer.stop(peer_pid)
        catch
          _, _ -> :ok
        end
      end)

      %{peer: peer_node}
    end

    test "a chain sealed on a peer under the shared configured key verifies locally", %{
      peer: peer
    } do
      key = :crypto.strong_rand_bytes(32)
      Application.put_env(:ash_a2a, :standing_ledger_key, key)
      :ok = :erpc.call(peer, Application, :put_env, [:ash_a2a, :standing_ledger_key, key])

      {:ok, received} =
        :erpc.call(peer, Standing, :transition, [
          candidate("urn:uuid:dep04-peer"),
          :received,
          @received
        ])

      assert {:ok, %Envelope{standing: :parsed}} = Standing.transition(received, :parsed, @parsed)
    end

    test "without a shared key the peer's chain is refused locally", %{peer: peer} do
      Application.delete_env(:ash_a2a, :standing_ledger_key)

      {:ok, received} =
        :erpc.call(peer, Standing, :transition, [
          candidate("urn:uuid:dep04-peer-local"),
          :received,
          @received
        ])

      assert {:error, %Refusal{code: :standing_ledger_unsealed}} =
               Standing.transition(received, :parsed, @parsed)
    end
  end
end
