# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.FuzzGen do
  @moduledoc false
  # Small deterministic seeded generator for the wire-decoder fuzz tests
  # (test/fuzz_*_test.exs). Every test calls `seed/1` first, so a failure
  # reproduces from the printed seed. Pure `:rand`, no extra dependency.

  @base_seed 20_261_115

  @doc "Seeds the calling process; the same `extra` always yields the same stream."
  def seed(extra \\ 0) do
    :rand.seed(:exsss, {@base_seed, extra, 7})
    :ok
  end

  @doc "Random integer in 0..n-1."
  def int(n) when n > 0, do: :rand.uniform(n) - 1

  def pick(list), do: Enum.at(list, int(length(list)))

  @doc """
  Runs `fun` in a task with a deadline. Returns `{:ok, value}`,
  `{:raised, kind, reason}` or `:timeout`; never raises itself.
  """
  def run_with_deadline(fun, ms \\ 10_000) do
    task =
      Task.async(fn ->
        try do
          {:ok, fun.()}
        rescue
          e -> {:raised, :error, e}
        catch
          kind, reason -> {:raised, kind, reason}
        end
      end)

    case Task.yield(task, ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> :timeout
    end
  end

  def random_bytes(n), do: for(_ <- 1..n//1, into: <<>>, do: <<int(256)>>)

  def big_string, do: String.duplicate("a", 1_000_000)

  def huge_int, do: String.to_integer(String.duplicate("9", 5_000))

  def number do
    pick([
      0,
      -1,
      1,
      9_223_372_036_854_775_807,
      9_223_372_036_854_775_808,
      18_446_744_073_709_551_616,
      -9_223_372_036_854_775_809,
      huge_int(),
      1.0e308,
      -0.0,
      1.5
    ])
  end

  def evil_string do
    case int(9) do
      0 -> ""
      1 -> <<255, 254, 253>>
      2 -> <<0xC0, 0x80>>
      3 -> "\u0000"
      4 -> String.duplicate("é", 1_000)
      5 -> "\u202E\uFEFF"
      6 -> random_bytes(1 + int(64))
      7 -> "\\u00"
      8 -> String.duplicate("x", 10_000)
    end
  end

  def scalar do
    case int(7) do
      0 -> nil
      1 -> pick([true, false])
      2 -> number()
      3 -> pick(["text", "task-1", "ROLE_USER", "completed", "2026-01-01T00:00:00Z"])
      4 -> evil_string()
      5 -> []
      6 -> %{}
    end
  end

  @keys ~w(id contextId status state message messageId role parts text kind file data
           history artifacts metadata name skills capabilities pageSize pageToken
           historyLength timeline generation taskId params method jsonrpc)

  def key, do: if(int(8) == 0, do: evil_string(), else: pick(@keys))

  @doc "Random JSON-like term of at most `depth` nesting and `width` children."
  def term(depth, width) do
    if depth <= 0 or int(3) == 0 do
      scalar()
    else
      n = int(width + 1)

      if int(2) == 0 do
        for _ <- 1..n//1, do: term(depth - 1, width)
      else
        Map.new(for(_ <- 1..n//1, do: {key(), term(depth - 1, width)}))
      end
    end
  end

  @doc "Replaces invalid-UTF-8 strings (and keys) so the term is Jason-encodable."
  def json_safe(%{} = map),
    do: Map.new(map, fn {k, v} -> {json_safe(k), json_safe(v)} end)

  def json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  def json_safe(bin) when is_binary(bin), do: if(String.valid?(bin), do: bin, else: "?")
  def json_safe(other), do: other

  @doc "A value of (probably) the wrong type for any field."
  def wrong_value, do: term(2, 3)

  @doc "Randomly replaces, nulls or recursively corrupts the fields of `value`."
  def corrupt(%{} = map) do
    Map.new(map, fn {k, v} ->
      case int(6) do
        0 -> {k, wrong_value()}
        1 -> {k, nil}
        2 -> {k, corrupt(v)}
        _ -> {k, v}
      end
    end)
  end

  def corrupt(list) when is_list(list), do: Enum.map(list, &if(int(4) == 0, do: corrupt(&1), else: &1))
  def corrupt(other), do: if(int(3) == 0, do: wrong_value(), else: other)

  @doc "Nested array body `depth` deep (valid JSON)."
  def nested_array(depth), do: String.duplicate("[", depth) <> String.duplicate("]", depth)

  @doc "Raw request bodies covering the hostile shapes from the lane brief."
  def raw_body do
    case int(10) do
      0 -> nested_array(1 + int(200))
      1 -> String.duplicate("[", 1 + int(5_000))
      2 -> ~s({"a":1,"a":2,"a":null,"a":[]})
      3 -> ~s({"text":") <> random_bytes(1 + int(128)) <> ~s("})
      4 -> ~s({"n":) <> String.duplicate("9", 1 + int(2_000)) <> "}"
      5 -> ~s({"n":1e) <> String.duplicate("9", 1 + int(20)) <> "}"
      6 -> ~s({"s":") <> big_string() <> ~s("})
      7 -> random_bytes(int(256))
      8 -> Jason.encode!(json_safe(term(4, 4))) |> binary_part(0, 1) |> Kernel.<>(random_bytes(int(32)))
      9 -> ~s({"a":[[{"b":"\\\\"}]],"c":null)
    end
  end

  # ---- Valid fixtures used for round-trip stability ----

  def valid_message do
    %{
      "messageId" => "m-#{int(1_000)}",
      "role" => pick(["ROLE_USER", "ROLE_AGENT"]),
      "parts" => [%{"text" => pick(["hi", "héllo", "", evil_utf8_safe()])}],
      "metadata" => %{"k" => pick([1, "v", nil, [1, 2]])}
    }
  end

  defp evil_utf8_safe, do: pick(["\u0000", String.duplicate("é", 50), "\u202E"])

  def valid_task do
    %{
      "id" => "t-#{int(1_000)}",
      "contextId" => "c-1",
      "status" => %{"state" => pick(["TASK_STATE_SUBMITTED", "TASK_STATE_COMPLETED"])},
      "history" => [valid_message()]
    }
  end

  def valid_card do
    %{
      "name" => "test",
      "description" => "d",
      "version" => "1",
      "supportedInterfaces" => [],
      "capabilities" => %{},
      "defaultInputModes" => ["text/plain"],
      "defaultOutputModes" => ["text/plain"],
      "skills" => [%{"id" => "s1", "name" => "Skill", "description" => "Does", "tags" => []}]
    }
  end

  def valid_list_request do
    %{"pageSize" => 1 + int(100), "contextId" => "c-1", "includeArtifacts" => pick([true, false])}
  end
end
