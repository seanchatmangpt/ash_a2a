defmodule AshA2A.V11.ClientGenerationTest do
  @moduledoc """
  Pure V11 courts: generation gap / unsupported rules, annotate/2, timeline
  helpers and the client's local v1.1 guards. No network.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Protocol.{AgentCard, Artifact, Client, Message, TimelineEntry}
  alias AshA2A.Protocol.Client.Generation
  alias AshA2A.Protocol.Event.{ArtifactUpdate, MessageUpdate, StatusUpdate}
  alias AshA2A.Protocol.Task, as: T

  defp status(gen), do: %StatusUpdate{task_id: "t1", status: %T.Status{state: :working, timestamp: "2026-01-01T00:00:00Z"}, generation: gen, final: false}
  defp snapshot(gen), do: %T{id: "t1", status: %T.Status{state: :working, timestamp: "2026-01-01T00:00:00Z"}, generation: gen}

  describe "Generation.observe/2" do
    test "consecutive generations are ok" do
      {results, state} = Generation.fold([snapshot(1), status(2), status(3)])
      assert Enum.map(results, &elem(&1, 1)) == [:ok, :ok, :ok]
      assert state.last == 3
    end

    test "N then N+2 is a gap and tracking continues from the new generation" do
      {results, state} = Generation.fold([snapshot(1), status(2), status(4), status(5)])

      assert Enum.map(results, &elem(&1, 1)) == [:ok, :ok, {:gap, 3, 4}, :ok]
      assert state.last == 5
      assert state.gap == nil
    end

    test "generation 0 or absent marks the server unsupported, permanently" do
      {results, state} = Generation.fold([status(0), status(1), status(2)])
      assert Enum.map(results, &elem(&1, 1)) == [:unsupported, :unsupported, :unsupported]
      assert state.unsupported

      {results, state} = Generation.fold([snapshot(1), status(nil)])
      assert Enum.map(results, &elem(&1, 1)) == [:ok, :unsupported]
      assert state.unsupported
    end

    test "two consecutive identical generations mean unsupported" do
      {results, state} = Generation.fold([status(3), status(3), status(4)])
      assert Enum.map(results, &elem(&1, 1)) == [:ok, :unsupported, :unsupported]
      assert state.unsupported
    end

    test "a snapshot resynchronises across a jump without reporting a gap" do
      {results, state} = Generation.fold([status(2), snapshot(9), status(10)])
      assert Enum.map(results, &elem(&1, 1)) == [:ok, :ok, :ok]
      assert state.last == 10
    end

    test "non-generational elements are ignored" do
      msg = Message.new_user("hi")
      err = %AshA2A.Protocol.StreamError{code: "ABORTED"}
      {results, state} = Generation.fold([msg, err], Generation.new(last_seen: 4))
      assert Enum.map(results, &elem(&1, 1)) == [:ignore, :ignore]
      assert state.last == 4
    end

    test "resubscribe seed: first event after last_seen is checked against it" do
      assert {[{_, :ok}], _} = Generation.fold([status(5)], Generation.new(last_seen: 4))
      assert {[{_, {:gap, 5, 7}}], _} = Generation.fold([status(7)], Generation.new(last_seen: 4))
    end

    test "message and artifact updates carry generation too" do
      art = %ArtifactUpdate{task_id: "t1", artifact: %Artifact{parts: [], artifact_id: "a"}, generation: 2}
      upd = %MessageUpdate{task_id: "t1", message: Message.new_user("x"), generation: 4}
      {results, _} = Generation.fold([snapshot(1), art, upd])
      assert Enum.map(results, &elem(&1, 1)) == [:ok, :ok, {:gap, 3, 4}]
    end
  end

  describe "Generation.annotate/2" do
    test "wraps elements and emits gap and unsupported annotations in order" do
      out = Enum.to_list(Generation.annotate([snapshot(1), status(3), status(3)]))

      assert [
               {:event, %T{}},
               {:gap, 2, 3},
               {:event, %StatusUpdate{generation: 3}},
               {:generation, :unsupported},
               {:event, %StatusUpdate{generation: 3}}
             ] = out
    end

    test "unsupported is announced once" do
      out = Enum.to_list(Generation.annotate([status(0), status(0), status(0)]))
      assert Enum.count(out, &(&1 == {:generation, :unsupported})) == 1
      assert Enum.count(out, &match?({:event, _}, &1)) == 3
    end
  end

  describe "timeline helpers" do
    defp entry(gen, kind), do: %TimelineEntry{entry: kind, generation: gen}

    defp task_with(timeline, artifacts \\ []),
      do: %T{id: "t1", status: %T.Status{state: :working, timestamp: "2026-01-01T00:00:00Z"}, timeline: timeline, artifacts: artifacts}

    test "timeline/1 sorts by generation and skips unknown entries" do
      m = {:message, Message.new_user("a")}
      s = {:status, %T.Status{state: :working, timestamp: "2026-01-01T00:00:00Z"}}

      task = task_with([entry(3, s), entry(2, {:unknown, %{"x" => 1}}), entry(1, m)])
      assert [%TimelineEntry{generation: 1}, %TimelineEntry{generation: 3}] = Client.timeline(task)
    end

    test "interleave_artifacts/1 orders by start generation, entries first on ties" do
      s = {:status, %T.Status{state: :working, timestamp: "2026-01-01T00:00:00Z"}}
      m = {:message, Message.new_user("a")}

      task =
        task_with(
          [entry(1, m), entry(2, s), entry(4, s)],
          [
            %Artifact{parts: [], artifact_id: "late", start_generation: 4},
            %Artifact{parts: [], artifact_id: "mid", start_generation: 2, end_generation: 3},
            %Artifact{parts: [], artifact_id: "none"}
          ]
        )

      assert [
               {:entry, %{generation: 1}},
               {:entry, %{generation: 2}},
               {:artifact, %{artifact_id: "mid"}},
               {:entry, %{generation: 4}},
               {:artifact, %{artifact_id: "late"}},
               {:artifact, %{artifact_id: "none"}}
             ] = Client.interleave_artifacts(task)
    end
  end

  describe "client v1.1 defaults and local guards" do
    test "default A2A-Version is 1.1; version: \"1.0\" overrides" do
      assert Client.new("http://127.0.0.1:1").version == "1.1"
      assert Client.new("http://127.0.0.1:1", version: "1.0").version == "1.0"
      pairs = header_pairs(Client.new("http://127.0.0.1:1").req.headers)
      assert {"a2a-version", "1.1"} in pairs
    end

    test "artifact_updates refused locally without the userArtifacts capability" do
      card = %AgentCard{name: "n", description: "d", url: "http://127.0.0.1:1", version: "1", skills: [], capabilities: %{streaming: true}}
      client = Client.new("http://127.0.0.1:1", transport: :http_json, card: card)

      assert {:error, :user_artifacts_not_supported} =
               Client.send_message(client, nil, task_id: "t1", artifact_updates: [%{"taskId" => "t1"}])

      assert {:error, :user_artifacts_not_supported} =
               Client.stream_message(client, "x", artifact_updates: [%{"taskId" => "t1"}])
    end

    test "message is required unless artifact_updates stand in" do
      client = Client.new("http://127.0.0.1:1", transport: :http_json)
      assert {:error, :message_required} = Client.send_message(client, nil)
    end
  end

  defp header_pairs(headers) when is_map(headers) do
    for {k, vs} <- headers, v <- List.wrap(vs), do: {k, v}
  end

  defp header_pairs(headers), do: headers
end
