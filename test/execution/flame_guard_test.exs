# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# Real-collaborator court for the testable parts of `AshA2A.Execution.FLAME`.
# Limitation (stated): a real FLAME pool/node is not available in-process, so
# the FLAME.call branch itself is covered by test/ash_a2a/flame_*_test.exs when
# FLAME is present; here `guarded/1` and `classify/2` (the extracted result
# handling) are exercised with real RuntimeReceipts and a real Receipt struct.
defmodule AshA2A.Execution.FlameGuardTest do
  use ExUnit.Case, async: true

  alias AshA2A.Execution.FLAME, as: Adapter
  alias AshA2A.RuntimeReceipt

  defp placement,
    do: RuntimeReceipt.new(:flame, :call, "cmd-1", {:ok, :x}, metadata: %{pool: "p"})

  test "guarded passes a normal return through" do
    assert {:ok, 1} = Adapter.guarded(fn -> {:ok, 1} end)
  end

  test "guarded types a raise" do
    assert {:error, {:exception, ArgumentError, "boom"}} =
             Adapter.guarded(fn -> raise ArgumentError, "boom" end)
  end

  test "guarded types a throw" do
    assert {:error, {:throw, :ball}} = Adapter.guarded(fn -> throw(:ball) end)
  end

  test "guarded types an exit (pool/node failure shape)" do
    assert {:error, {:exit, :noproc}} = Adapter.guarded(fn -> exit(:noproc) end)
  end

  test "classify: success carries receipt and placement" do
    receipt = struct(AshA2A.Receipt)
    p = placement()
    assert {:ok, %{receipt: ^receipt, placement: ^p}} = Adapter.classify({:ok, receipt}, p)
  end

  test "classify: error keeps reason and placement" do
    p = placement()
    assert {:error, %{reason: :nope, placement: ^p}} = Adapter.classify({:error, :nope}, p)
  end

  test "classify: unexpected branch is typed, with placement" do
    p = placement()

    assert {:error, %{reason: {:unexpected_flame_result, :weird}, placement: ^p}} =
             Adapter.classify(:weird, p)

    assert {:error, %{reason: {:unexpected_flame_result, {:ok, :not_a_receipt}}}} =
             Adapter.classify({:ok, :not_a_receipt}, p)
  end

  test "run/5 without FLAME fails closed unsupported (when FLAME absent)" do
    unless Adapter.available?() do
      command = struct(AshA2A.Command, command_id: "c")
      message = AshA2A.Protocol.Message.new_user("hi")
      assert {:error, {:unsupported, :flame}} = Adapter.run(:pool, command, message, __MODULE__)
    end
  end
end
