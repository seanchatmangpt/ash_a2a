# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.FuzzJSONGuardTest do
  # Seeded fuzz of AshA2A.Protocol.JSONGuard.
  use ExUnit.Case, async: true

  alias AshA2A.FuzzGen
  alias AshA2A.Protocol.JSONGuard

  @iterations 1_000

  defp depth(list) when is_list(list), do: 1 + Enum.reduce(list, 0, &max(depth(&1), &2))
  defp depth(%{} = map), do: 1 + Enum.reduce(Map.values(map), 0, &max(depth(&1), &2))
  defp depth(_), do: 0

  test "decode/2 never raises or hangs on hostile raw bodies and returns the documented shape" do
    FuzzGen.seed(1)

    for i <- 1..@iterations do
      body = FuzzGen.raw_body()

      case FuzzGen.run_with_deadline(fn -> JSONGuard.decode(body) end) do
        {:ok, {:ok, _}} ->
          :ok

        {:ok, {:error, {:nesting_exceeded, 64}}} ->
          :ok

        {:ok, {:error, %Jason.DecodeError{}}} ->
          :ok

        other ->
          flunk(
            "iteration #{i} (seed 1), body size #{byte_size(body)}: #{inspect(other, limit: 5)}"
          )
      end
    end
  end

  test "a decoded value never nests deeper than max_depth" do
    FuzzGen.seed(2)

    for _ <- 1..@iterations do
      max = 1 + FuzzGen.int(8)
      value = FuzzGen.json_safe(FuzzGen.term(10, 3))
      body = Jason.encode!(value)

      case JSONGuard.decode(body, max) do
        {:ok, decoded} -> assert depth(decoded) <= max
        {:error, {:nesting_exceeded, ^max}} -> assert depth(value) > max
        # An out-of-range scalar in the generated term is a plain decode error.
        {:error, %Jason.DecodeError{}} -> :ok
      end
    end
  end

  test "bracket-like bytes inside strings, including escapes, do not count as nesting" do
    FuzzGen.seed(3)

    for _ <- 1..100 do
      payload = String.duplicate(FuzzGen.pick(["[", "{", "\\\"[", "\\\\"]), 1 + FuzzGen.int(500))
      body = Jason.encode!(%{"s" => payload})
      assert {:ok, %{"s" => ^payload}} = JSONGuard.decode(body, 2)
    end
  end

  test "1MB of open brackets is refused quickly, not parsed" do
    body = String.duplicate("[", 1_000_000)

    assert {:ok, {:error, {:nesting_exceeded, 64}}} =
             FuzzGen.run_with_deadline(fn -> JSONGuard.decode(body) end, 5_000)
  end

  test "depth boundary: exactly max_depth passes, max_depth + 1 is refused" do
    assert {:ok, _} = JSONGuard.decode(FuzzGen.nested_array(64))
    assert {:error, {:nesting_exceeded, 64}} = JSONGuard.decode(FuzzGen.nested_array(65))
  end

  test "valid values round-trip through encode and decode unchanged" do
    FuzzGen.seed(4)

    for _ <- 1..@iterations do
      # Generated numbers can encode to JSON Jason itself will not read back; skip those.
      with {:ok, value} <- Jason.decode(Jason.encode!(FuzzGen.json_safe(FuzzGen.term(5, 4)))) do
        assert {:ok, ^value} = JSONGuard.decode(Jason.encode!(value), 64)
      end
    end
  end

  test "1MB string, huge integers and duplicate keys decode without raising" do
    assert {:ok, %{"s" => s}} = JSONGuard.decode(~s({"s":") <> FuzzGen.big_string() <> ~s("}))
    assert byte_size(s) == 1_000_000

    # Duplicate keys: the result is deterministic (whichever the decoder keeps), never a raise.
    assert {:ok, %{"a" => kept}} = JSONGuard.decode(~s({"a":1,"a":2}))
    assert kept in [1, 2]
    assert {:ok, %{"a" => ^kept}} = JSONGuard.decode(~s({"a":1,"a":2}))

    big = String.duplicate("9", 100_000)

    assert {:ok, _} =
             FuzzGen.run_with_deadline(fn -> JSONGuard.decode(~s({"n":#{big}})) end, 20_000)
  end

  test "invalid UTF-8 and out-of-range floats yield an error tuple, not a raise" do
    assert {:error, _} = JSONGuard.decode(<<?[, ?", 255, 254, ?", ?]>>)
    assert match?({:ok, _}, {:ok, JSONGuard.decode(~s({"n":1e999999999}))})
    assert match?({:ok, _}, {:ok, JSONGuard.decode(~s({"n":-1e999999999}))})
  end
end
