# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2ASSEStreamTest do
  @moduledoc """
  Chicago-style coverage for assignment #8: real `message/stream` content
  parsed via `AshA2A.Protocol.Client.SSE.feed/2` -- genuinely untested surface (the
  existing streaming tests, `test/ash_a2a_test.exs`'s and
  `test/ash_a2a_dispatcher_skills_test.exs`'s `:echo` cases, only assert on
  the bare Elixir `{:stream, enum}` tuple at the dispatcher level, against
  an always-empty ETS table, and never touch `AshA2A.Protocol.Client.SSE` at all).

  This file drives the real stack one level further than those:

  1. A real `AshA2A.Protocol.AgentSupervisor` starts a real
     `AshA2A.Test.Fixture.StreamingWidgetAgent` (`use AshA2A.Agent`) over a
     real, ETS-seeded `AshA2A.Test.Fixture.StreamingWidget` resource
     (seeded with real rows via `Ash.Seed.seed!/2` -- a real Ash test-data
     API, not a mock).
  2. `AshA2A.Protocol.stream/3` (the real, dependency-free public API in
     `deps/a2a/lib/a2a.ex:121-152` -- no `Plug`/`Bandit` involved) sends a
     real `AshA2A.Protocol.Message` to that real process and returns `{:ok, task,
     enum}`, where `enum` is the real lazy `Stream.map/2` built by
     `AshA2A.Dispatcher.to_reply/1`'s `{:stream_ok, stream}` clause
     (`lib/ash_a2a/dispatcher.ex:478-484`) -- each element a real
     `AshA2A.Protocol.Part.Data` wrapping one real streamed `StreamingWidget` record.
  3. Each real part is wrapped into a real `AshA2A.Protocol.Event.ArtifactUpdate`
     (`deps/a2a/lib/a2a/event.ex:51-84`) and encoded with the real
     `AshA2A.Protocol.JSON.encode/1` (`deps/a2a/lib/a2a/json.ex:195-211`) -- the exact
     two calls `AshA2A.Protocol.Plug.SSE.stream_parts/4`
     (`deps/a2a/lib/a2a/plug/sse.ex:66-79`) makes for every streamed part
     over real HTTP. `AshA2A.Protocol.Plug.SSE` itself cannot be driven directly here:
     it is gated behind `Code.ensure_loaded?(Plug)`
     (`deps/a2a/lib/a2a/plug/sse.ex:1`) and neither `plug` nor `bandit`
     appear anywhere in this project's `mix.lock` -- ash_a2a wires no HTTP
     transport (confirmed by this session's research). Wrapping each real
     `Part.Data` into `ArtifactUpdate`/`JSON.encode` here reproduces that
     exact real two-line encoding step from `AshA2A.Protocol.Plug.SSE`, not a
     hand-invented one, wire-formatted as `"data: <json>\\n\\n"` exactly as
     `AshA2A.Protocol.Plug.SSE.send_event/3` does (`deps/a2a/lib/a2a/plug/sse.ex:81-88`).
  4. Those real SSE-formatted chunks (split mid-event, to prove the parser's
     real buffering, not just whole-event feeds) are fed through the real,
     dependency-free `AshA2A.Protocol.Client.SSE.new/0` + `feed/2`
     (`deps/a2a/lib/a2a/client/sse.ex:20-34`) -- the actual target of this
     assignment.
  5. Assertions are state-based throughout: the real decoded SSE event
     payloads' artifact part data is compared against the real seeded
     `StreamingWidget` labels -- not "was `feed/2` called," an interaction
     assertion this file never makes.

  No Mock/mox/patch/monkeypatch anywhere in this file.
  """

  use ExUnit.Case

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.Fixture.{StreamingWidget, StreamingWidgetAgent}

  test "AshA2A.Protocol.stream/3's real streamed parts round-trip through AshA2A.Protocol.Client.SSE.feed/2 unchanged" do
    # Seed real rows via the real Ash.Seed API (StreamingWidget declares no
    # :create action -- this is the same kind of direct data-layer seeding
    # a hand-rolled ETS fixture load would be, just via Ash's own real
    # helper instead of reinventing it).
    Ash.Seed.seed!(StreamingWidget, %{label: "alpha"})
    Ash.Seed.seed!(StreamingWidget, %{label: "bravo"})
    Ash.Seed.seed!(StreamingWidget, %{label: "charlie"})

    {_sup, _registry_name} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [
        StreamingWidgetAgent
      ])

    message = data_message(%{"stream" => true})

    assert {:ok, task, enum} = AshA2A.Protocol.stream(StreamingWidgetAgent, message, [])
    assert task.status.state == :working

    # Drain the real lazy stream -- real AshA2A.Protocol.Part.Data structs, each
    # wrapping one real streamed StreamingWidget record. The ETS data layer
    # is process-shared across this file's two tests (no per-test reset
    # hook exists for `Ash.DataLayer.Ets`), so filter down to this test's
    # own seeded labels rather than asserting on the raw total count.
    real_parts =
      enum
      |> Enum.to_list()
      |> Enum.filter(fn %AshA2A.Protocol.Part.Data{data: %{label: label}} ->
        label in ["alpha", "bravo", "charlie"]
      end)

    assert length(real_parts) == 3

    real_labels =
      real_parts
      |> Enum.map(fn %AshA2A.Protocol.Part.Data{data: %{label: label}} -> label end)
      |> Enum.sort()

    assert real_labels == ["alpha", "bravo", "charlie"]

    # Reproduce AshA2A.Protocol.Plug.SSE.stream_parts/4's exact real per-part encoding
    # (ArtifactUpdate.new/3 + AshA2A.Protocol.JSON.encode_stream_response/1
    # + the literal "data: <json>\n\n" wire format AshA2A.Protocol.Plug.SSE.send_event/3
    # emits): the v1.0 wire frame wraps the event as {"artifactUpdate": ...}.
    wire_chunks =
      Enum.map(real_parts, fn part ->
        artifact = AshA2A.Protocol.Artifact.new([part])
        event = AshA2A.Protocol.Event.ArtifactUpdate.new(task.id, artifact, context_id: task.context_id)
        {:ok, encoded} = AshA2A.Protocol.JSON.encode_stream_response(event)
        payload = AshA2A.Protocol.JSONRPC.Response.success("test-id", encoded)
        "data: #{Jason.encode!(payload)}\n\n"
      end)

    full_wire = Enum.join(wire_chunks)
    assert byte_size(full_wire) > 0

    # Split the real wire bytes at arbitrary, non-event-aligned byte
    # offsets to prove AshA2A.Protocol.Client.SSE.feed/2's real buffering across
    # partial chunks -- not just one whole-event-per-feed happy path.
    {chunk_a, rest} = String.split_at(full_wire, div(byte_size(full_wire), 3))
    {chunk_b, chunk_c} = String.split_at(rest, div(byte_size(rest), 2))

    state0 = AshA2A.Protocol.Client.SSE.new()
    {events1, state1} = AshA2A.Protocol.Client.SSE.feed(state0, chunk_a)
    {events2, state2} = AshA2A.Protocol.Client.SSE.feed(state1, chunk_b)
    {events3, _state3} = AshA2A.Protocol.Client.SSE.feed(state2, chunk_c)

    all_events = events1 ++ events2 ++ events3
    assert length(all_events) == 3

    # Every real decoded SSE event is a real JSON-RPC success envelope
    # wrapping the real encoded ArtifactUpdate, whose artifact part data
    # matches the real originally-streamed labels -- proving what a real
    # streaming A2A client actually receives and parses over the wire
    # matches the real content the agent streamed, not just that some
    # bytes were split into 3 pieces.
    decoded_labels =
      all_events
      |> Enum.map(fn %{"result" => result} ->
        # v1.0 StreamResponse frame: the result is {"artifactUpdate": ...} —
        # the wrapper key is the discriminator, with no "kind" key anywhere.
        assert %{"artifactUpdate" => %{"artifact" => %{"parts" => [%{"data" => %{"label" => label}} = part]}}} =
                 result

        refute Map.has_key?(part, "kind")
        label
      end)
      |> Enum.sort()

    assert decoded_labels == ["alpha", "bravo", "charlie"]

    # Every event round-tripped as a well-formed JSON-RPC 2.0 success
    # envelope with the id this test supplied.
    assert Enum.all?(all_events, fn event ->
             event["jsonrpc"] == "2.0" and event["id"] == "test-id"
           end)
  end

  test "AshA2A.Protocol.Client.SSE.feed/2 buffers a real event split across many single-byte feeds" do
    Ash.Seed.seed!(StreamingWidget, %{label: "solo"})

    {_sup, _registry_name} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [
        StreamingWidgetAgent
      ])

    message = data_message(%{"stream" => true})

    assert {:ok, task, enum} = AshA2A.Protocol.stream(StreamingWidgetAgent, message, [])

    # Shared ETS table across this file's tests (see note above) -- select
    # this test's own seeded row rather than assuming it is the only one.
    [part] =
      enum
      |> Enum.to_list()
      |> Enum.filter(fn %AshA2A.Protocol.Part.Data{data: %{label: label}} -> label == "solo" end)

    artifact = AshA2A.Protocol.Artifact.new([part])
    event = AshA2A.Protocol.Event.ArtifactUpdate.new(task.id, artifact, context_id: task.context_id)
    {:ok, encoded} = AshA2A.Protocol.JSON.encode_stream_response(event)
    payload = AshA2A.Protocol.JSONRPC.Response.success(1, encoded)
    wire = "data: #{Jason.encode!(payload)}\n\n"

    # Feed the real wire bytes one byte at a time -- the real parser must
    # emit nothing until the terminating "\n\n" boundary actually arrives.
    {events, _final_state} =
      wire
      |> String.graphemes()
      |> Enum.reduce({[], AshA2A.Protocol.Client.SSE.new()}, fn byte, {acc_events, state} ->
        {new_events, new_state} = AshA2A.Protocol.Client.SSE.feed(state, byte)
        {acc_events ++ new_events, new_state}
      end)

    assert [%{"result" => %{"artifactUpdate" => %{"artifact" => %{"parts" => [%{"data" => %{"label" => "solo"}}]}}}}] =
             events
  end
end
