# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.FuzzJSONRPCRequestTest do
  # Seeded fuzz of the JSON-RPC request decoder.
  use ExUnit.Case, async: true

  alias AshA2A.FuzzGen
  alias AshA2A.Protocol.JSONGuard
  alias AshA2A.Protocol.JSONRPC.Error
  alias AshA2A.Protocol.JSONRPC.Request

  @iterations 1_500

  @methods [
    "message/send",
    "message/stream",
    "tasks/get",
    "tasks/cancel",
    "tasks/resubscribe",
    "tasks/list",
    "tasks/pushNotificationConfig/set",
    "tasks/pushNotificationConfig/get",
    "tasks/pushNotificationConfig/list",
    "tasks/pushNotificationConfig/delete",
    "unknown/method"
  ]

  defp envelope(params) do
    %{"jsonrpc" => "2.0", "id" => FuzzGen.pick(["1", 7, nil]), "method" => FuzzGen.pick(@methods),
      "params" => params}
  end

  defp decode_and_validate(raw) do
    with {:ok, req} <- Request.parse(raw), do: Request.validate_params(req)
  end

  test "parse + validate_params never raise or hang on corrupted envelopes" do
    FuzzGen.seed(20)

    for i <- 1..@iterations do
      raw =
        case FuzzGen.int(3) do
          0 -> FuzzGen.corrupt(envelope(FuzzGen.term(3, 4)))
          1 -> envelope(FuzzGen.corrupt(FuzzGen.valid_list_request()))
          2 -> FuzzGen.term(4, 4)
        end

      case FuzzGen.run_with_deadline(fn -> decode_and_validate(raw) end) do
        {:ok, :ok} -> :ok
        {:ok, {:error, %Error{}}} -> :ok
        other -> flunk("iteration #{i} (seed 20): #{inspect(other, limit: 8, printable_limit: 80)}")
      end
    end
  end

  test "raw bodies through JSONGuard then parse never raise or hang" do
    FuzzGen.seed(21)

    for i <- 1..200 do
      body = FuzzGen.raw_body()

      result =
        FuzzGen.run_with_deadline(fn ->
          case JSONGuard.decode(body) do
            {:ok, raw} -> decode_and_validate(raw)
            {:error, _} = e -> e
          end
        end)

      case result do
        {:ok, :ok} -> :ok
        {:ok, {:error, _}} -> :ok
        other -> flunk("iteration #{i} (seed 21): #{inspect(other, limit: 8, printable_limit: 80)}")
      end
    end
  end

  test "non-object requests are refused with invalid_request" do
    for raw <- [nil, [], "x", 1, true, FuzzGen.big_string()] do
      assert {:error, %Error{}} = Request.parse(raw)
    end
  end

  test "valid envelopes round-trip through JSON text and parse to the same request" do
    FuzzGen.seed(22)

    for _ <- 1..@iterations do
      raw = envelope(FuzzGen.json_safe(%{"id" => "t-1", "pageSize" => 1 + FuzzGen.int(100)}))
      assert {:ok, ^raw} = JSONGuard.decode(Jason.encode!(raw))
      assert {:ok, req} = Request.parse(raw)
      assert req.method == raw["method"]
      assert req.id == raw["id"]
      assert req.params == raw["params"]
      assert Request.parse(raw) == {:ok, req}
    end
  end

  test "wrong-typed ids and params are handled deterministically" do
    for id <- [1.5, true, [], %{}] do
      assert {:error, %Error{}} =
               Request.parse(%{"jsonrpc" => "2.0", "id" => id, "method" => "tasks/list"})
    end

    assert {:ok, %Request{params: %{}}} =
             Request.parse(%{"jsonrpc" => "2.0", "id" => 1, "method" => "m", "params" => nil})
  end
end
