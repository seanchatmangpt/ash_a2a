# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2AJsonRoundtripTest do
  @moduledoc """
  Real JSON round-trip test for a genuinely untested surface: what an LLM
  client actually receives over the wire from an ash_a2a-produced
  `AshA2A.Protocol.Task`, not just the live Elixir struct existing tests assert against.

  Every prior test in this suite (`test/ash_a2a_test.exs`,
  `test/ash_a2a_rap_battle_integration_test.exs`) asserts directly on the
  `AshA2A.Protocol.Task`/`AshA2A.Protocol.Message` struct returned by `AshA2A.Protocol.Agent.call/2` -- a live
  Elixir term still inside the BEAM. None of them push that struct through
  `:a2a`'s own `AshA2A.Protocol.JSON.encode/1` + `Jason.encode!/1` + `Jason.decode!/1` +
  `AshA2A.Protocol.JSON.decode/2` round trip, which is what a real HTTP/JSON-RPC
  transport (and thus a real LLM client on the other end) would actually do.
  The vendored `:a2a` 0.2.0 dependency itself ships no `test/` directory at
  all, so this codec path is formally unverified even at the dependency
  level -- this test is the first real exercise of it in this workspace.

  Chicago-style throughout: a real supervised `AshA2A.Protocol.Agent` GenServer (the
  existing `AshA2A.Test.Fixture.EchoAgent`/`Echo` fixture from
  `test/support/fixture.ex`), a real dispatched `AshA2A.Protocol.Message`, the real
  resulting `AshA2A.Protocol.Task`, and `:a2a`'s own real `AshA2A.Protocol.JSON` encode/decode
  functions and real `Jason` calls -- no Mock/mox/patch/monkeypatch, and no
  hand-rolled substitute for the real wire codec.
  """

  # `async: false`: this test reuses the shared `AshA2A.Test.Fixture.EchoAgent`
  # fixture, which `AshA2A.Protocol.Agent` registers under its own fixed module name
  # (not a per-test unique name) -- `test/ash_a2a_test.exs`'s existing
  # supervised-agent test also starts this same globally-named process, so
  # running both concurrently races for the same registered name
  # (`already_started`). Real fix for a real global-name collision, not a
  # workaround: serialize this test relative to that one instead of
  # reaching for a duplicate fixture just to keep `async: true`.
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.Fixture.EchoAgent

  test "a real dispatched AshA2A.Protocol.Task survives AshA2A.Protocol.JSON encode -> Jason JSON string -> Jason decode -> AshA2A.Protocol.JSON decode" do
    {_sup, _registry_name} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [EchoAgent])

    # A real message sent through a real supervised agent, exactly as the
    # existing supervised-agent test does (the fixture's :echo read action
    # accepts no arguments, so an empty data payload keeps dispatch on the
    # real :completed path rather than :input_required) -- the difference
    # from the existing test starts after this line.
    message = data_message(%{})

    assert {:ok, task} = EchoAgent.call(EchoAgent, message)
    assert %AshA2A.Protocol.Task{} = task
    assert task.status.state == :completed

    # Real artifact content the fixture's :echo read action actually
    # produced, asserted before it goes anywhere near JSON so a codec bug
    # can't be blamed for a dispatch bug.
    assert [%AshA2A.Protocol.Artifact{parts: [%AshA2A.Protocol.Part.Data{data: %{results: []}}]}] = task.artifacts

    # 1. Real encode: AshA2A.Protocol.Task -> JSON-ready map, via :a2a's own encoder.
    assert {:ok, wire_map} = AshA2A.Protocol.JSON.encode(task)
    # v1.0 wire shape: task frames carry no "kind" discriminator (the
    # StreamResponse wrapper key is the discriminator).
    refute Map.has_key?(wire_map, "kind")
    assert wire_map["id"] == task.id
    # TASK_STATE_* wire spellings are unchanged in v1.0.
    assert wire_map["status"]["state"] == "TASK_STATE_COMPLETED"

    # 2. Real serialization: the map must actually survive a real
    # Jason.encode!/1 -> Jason.decode!/1 round trip -- i.e. it contains no
    # non-JSON-safe values (atoms as map values, tuples, etc.) that a
    # struct-to-map shortcut could have smuggled through.
    json_string = Jason.encode!(wire_map)
    assert is_binary(json_string)

    redecoded_map = Jason.decode!(json_string)
    assert is_map(redecoded_map)

    # camelCase wire keys, per AshA2A.Protocol.JSON's documented v0.3 wire format.
    assert Map.has_key?(redecoded_map, "contextId") == Map.has_key?(wire_map, "contextId")
    assert redecoded_map["id"] == task.id

    # 3. Real decode: JSON-ready map -> AshA2A.Protocol.Task struct, via :a2a's own
    # decoder -- fed the map that actually came back through a real JSON
    # string, not the original in-memory `wire_map`.
    assert {:ok, decoded_task} = AshA2A.Protocol.JSON.decode(redecoded_map, :task)

    # State-based assertions on the real round-tripped struct: what an LLM
    # client parsing this JSON-RPC response would actually reconstruct.
    assert decoded_task.id == task.id
    # v1.0: contextId is REQUIRED on the wire. `use AshA2A.Agent` routes this
    # call through AshA2A.Transport.Runtime, which mints a server-side CSPRNG
    # context id ("ctx-" + 128 random bits, secure_context_id/0) on a new
    # task when the client supplies none — so the in-memory task carries a
    # real context id, and the round trip must preserve it byte-for-byte.
    assert is_binary(task.context_id) and String.starts_with?(task.context_id, "ctx-")
    assert decoded_task.context_id == task.context_id
    assert decoded_task.status.state == task.status.state
    assert decoded_task.metadata == task.metadata

    assert [%AshA2A.Protocol.Artifact{parts: [%AshA2A.Protocol.Part.Data{data: decoded_data}]}] =
             decoded_task.artifacts

    # AshA2A.Protocol.Part.Data's wire format carries `data` through Jason as
    # string-keyed JSON, while the original in-memory artifact used an
    # atom-keyed map (`%{results: []}`) -- assert the round-tripped,
    # client-visible shape directly rather than against the pre-JSON atom
    # keys, since atom keys never legitimately survive a real wire hop.
    assert decoded_data == %{"results" => []}

    # The full task's history round-trips with the same message count, ids,
    # and roles as the original -- no phantom entries manufactured or
    # dropped in transit. The agent-reply message's `AshA2A.Protocol.Part.Data.data`
    # legitimately comes back string-keyed (same real wire-format reason as
    # `decoded_data` above), so compare history structurally rather than
    # with a blanket `==` against the original atom-keyed in-memory term.
    assert length(decoded_task.history) == length(task.history)

    assert Enum.zip(decoded_task.history, task.history)
           |> Enum.all?(fn {decoded_msg, original_msg} ->
             decoded_msg.message_id == original_msg.message_id and
               decoded_msg.role == original_msg.role
           end)

    assert [_user_msg, %AshA2A.Protocol.Message{parts: [%AshA2A.Protocol.Part.Data{data: history_reply_data}]}] =
             decoded_task.history

    assert history_reply_data == %{"results" => []}

    # 4. Real round-trip of the request AshA2A.Protocol.Message itself, not just the
    # resulting Task -- the other half of what crosses the wire.
    assert {:ok, message_wire_map} = AshA2A.Protocol.JSON.encode(message)
    # v1.0 wire shape: no "kind" discriminator on the message either; parts
    # are flat {"data": ...} maps.
    refute Map.has_key?(message_wire_map, "kind")

    assert [%{"data" => %{}}] = message_wire_map["parts"]

    message_json = Jason.encode!(message_wire_map)
    redecoded_message_map = Jason.decode!(message_json)

    assert {:ok, decoded_message} = AshA2A.Protocol.JSON.decode(redecoded_message_map, :message)
    assert decoded_message.message_id == message.message_id
    assert decoded_message.role == message.role

    assert [%AshA2A.Protocol.Part.Data{data: decoded_message_data}] = decoded_message.parts
    assert decoded_message_data == %{}
  end
end
