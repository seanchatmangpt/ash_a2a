# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.FuzzJSONDecodersTest do
  # Seeded fuzz of the AshA2A.Protocol.JSON decoders. Every public decoder is
  # total: any term in gives {:ok, _}, {:error, _} (or {:skip, _} for an unknown
  # stream payload), never a raise and never a hang. A raising input fails the
  # test; see docs/reference/fuzz-findings-v26.11.15.md.
  use ExUnit.Case, async: true

  alias AshA2A.FuzzGen
  alias AshA2A.Protocol.JSON

  @iterations 2_000

  @decode_types [
    :task,
    :status,
    :message,
    :artifact,
    :part,
    :file_content,
    :event,
    :status_update_event,
    :artifact_update_event,
    :push_notification_config,
    :timeline_entry,
    :message_update_event,
    :stream_error
  ]

  # Returns the list of {label, input, exception} that raised; fails on timeout
  # or on a result outside the documented shape.
  defp fuzz(label, inputs, fun) do
    Enum.flat_map(inputs, fn input ->
      case FuzzGen.run_with_deadline(fn -> fun.(input) end) do
        {:ok, {:ok, _}} -> []
        {:ok, {:error, _}} -> []
        {:ok, {:skip, _}} -> []
        {:raised, kind, reason} -> [{label, input, {kind, reason}}]
        :timeout -> flunk("#{label} hung on #{inspect(input, limit: 8)}")
        other -> flunk("#{label} returned #{inspect(other, limit: 8)}")
      end
    end)
  end

  defp report(raises) do
    if raises != [] do
      IO.puts(
        "[fuzz] #{length(raises)} raising input(s), first: " <>
          inspect(hd(raises), limit: 6, printable_limit: 80)
      )
    end

    assert raises == []
  end

  defp mutated(gen), do: for(_ <- 1..@iterations, do: FuzzGen.corrupt(gen.()))
  defp random_terms, do: for(_ <- 1..@iterations, do: FuzzGen.term(4, 4))

  test "decode(:message) is total over corrupted and random maps" do
    FuzzGen.seed(10)
    inputs = mutated(&FuzzGen.valid_message/0) ++ random_terms()
    report(fuzz(:message, inputs, &JSON.decode(&1, :message)))
  end

  test "decode(:task) is total over corrupted and random maps" do
    FuzzGen.seed(11)
    inputs = mutated(&FuzzGen.valid_task/0) ++ random_terms()
    report(fuzz(:task, inputs, &JSON.decode(&1, :task)))
  end

  test "decode_agent_card is total over corrupted and random maps" do
    FuzzGen.seed(12)
    inputs = mutated(&FuzzGen.valid_card/0) ++ mutated(&FuzzGen.full_card/0) ++ random_terms()
    report(fuzz(:agent_card, inputs, &JSON.decode_agent_card/1))
  end

  test "decode_list_tasks_request is total over corrupted and random maps" do
    FuzzGen.seed(13)
    inputs = mutated(&FuzzGen.valid_list_request/0) ++ random_terms()
    report(fuzz(:list_request, inputs, &JSON.decode_list_tasks_request/1))
  end

  test "decode/2 is total for every decode type over corrupted and random terms" do
    FuzzGen.seed(16)

    inputs =
      mutated(&FuzzGen.valid_message/0) ++
        mutated(&FuzzGen.valid_task/0) ++
        mutated(&FuzzGen.valid_event/0) ++
        mutated(&FuzzGen.valid_artifact/0) ++
        mutated(&FuzzGen.valid_push_config/0) ++ random_terms()

    for type <- @decode_types do
      report(fuzz(type, inputs, &JSON.decode(&1, type)))
    end
  end

  test "the request and envelope decoders are total over any term" do
    FuzzGen.seed(17)

    inputs =
      mutated(&FuzzGen.valid_send_request/0) ++
        mutated(&FuzzGen.valid_stream_request/0) ++
        mutated(&FuzzGen.valid_list_result/0) ++ random_terms()

    for {label, fun} <- [
          send_message_request: &JSON.decode_send_message_request/1,
          send_message_configuration: &JSON.decode_send_message_configuration/1,
          get_task_request: &JSON.decode_get_task_request/1,
          subscribe_request: &JSON.decode_subscribe_request/1,
          stream_request: &JSON.decode_stream_request/1,
          list_result: &JSON.decode_list_result/1,
          state: &JSON.decode_state/1
        ] do
      report(fuzz(label, inputs, fun))
    end
  end

  test "a wrong-typed member is a typed refusal, not a raise" do
    header = %{"messageId" => "m", "role" => "ROLE_USER"}
    status = %{"state" => "TASK_STATE_COMPLETED"}

    assert {:error, {:invalid_field, "message"}} = JSON.decode(1, :message)

    assert {:error, {:invalid_field, "parts"}} =
             JSON.decode(Map.put(header, "parts", "x"), :message)

    assert {:error, {:invalid_field, "part"}} =
             JSON.decode(Map.put(header, "parts", [1]), :message)

    assert {:error, {:invalid_field, "history"}} =
             JSON.decode(%{"id" => "t", "status" => status, "history" => 5}, :task)

    assert {:error, {:invalid_field, "status"}} =
             JSON.decode(%{"id" => "t", "status" => 5}, :task)

    for field <- ["skills", "capabilities"] do
      assert {:error, {:invalid_field, ^field}} =
               JSON.decode_agent_card(Map.put(FuzzGen.valid_card(), field, 5))
    end

    assert {:error, {:invalid_field, "agentCard"}} = JSON.decode_agent_card(5)
    assert {:error, {:invalid_params, _}} = JSON.decode_list_tasks_request(5)
    assert {:error, {:missing_field, "id"}} = JSON.decode_get_task_request([])
    assert {:error, {:missing_field, "id"}} = JSON.decode_subscribe_request(nil)
  end

  test "an oversized int64 string is ignored without building a bignum" do
    wire = Map.put(FuzzGen.valid_task(), "generation", String.duplicate("9", 1_000_000))

    assert {:ok, {:ok, task}} =
             FuzzGen.run_with_deadline(fn -> JSON.decode(wire, :task) end, 2_000)

    assert task.generation == 1
  end

  test "non-map and null payloads do not hang any decoder" do
    for input <- [nil, [], "s", 1, 1.5, true, FuzzGen.big_string()],
        type <- [:message, :task, :status, :artifact, :part, :event] do
      assert FuzzGen.run_with_deadline(fn -> JSON.decode(input, type) end) != :timeout
    end
  end

  test "decoders return promptly on 1MB strings in every string field" do
    big = FuzzGen.big_string()

    message = %{
      "messageId" => big,
      "role" => "ROLE_USER",
      "parts" => [%{"text" => big}],
      "metadata" => %{big => big}
    }

    assert {:ok, {:ok, _}} = FuzzGen.run_with_deadline(fn -> JSON.decode(message, :message) end)
  end

  test "valid messages round-trip: decode -> encode -> decode is stable" do
    FuzzGen.seed(14)

    for _ <- 1..@iterations do
      wire = FuzzGen.valid_message()
      assert {:ok, first} = JSON.decode(wire, :message)
      assert {:ok, encoded} = JSON.encode(first)
      reparsed = encoded |> Jason.encode!() |> Jason.decode!()
      assert {:ok, ^first} = JSON.decode(reparsed, :message)
    end
  end

  test "valid tasks round-trip: decode -> encode -> decode is stable" do
    FuzzGen.seed(15)

    for _ <- 1..@iterations do
      wire = FuzzGen.valid_task()
      assert {:ok, first} = JSON.decode(wire, :task)
      assert {:ok, encoded} = JSON.encode(first)
      reparsed = encoded |> Jason.encode!() |> Jason.decode!()
      assert {:ok, ^first} = JSON.decode(reparsed, :task)
    end
  end

  test "the valid agent card fixture decodes" do
    assert {:ok, _} = JSON.decode_agent_card(FuzzGen.valid_card())
  end
end
