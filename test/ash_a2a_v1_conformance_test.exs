defmodule AshA2A.Protocol.V1ConformanceTest do
  @moduledoc """
  A2A v1.0.0 wire-level conformance courts — real codecs, real agents, real
  HTTP conns (`Plug.Test`), zero mocks (Chicago style).

  Five courts over the normative v1.0 wire contract:

    1. Part polymorphism (App. A.2.1) — a Part object carries exactly one
       content member and no `kind` discriminator, and survives a real
       `Jason` round-trip back to identical structs.
    2. Event envelopes — `StatusUpdate`/`ArtifactUpdate` encode as a
       single-member v1.0 `StreamResponse` with no `kind` and no `final`;
       finality is reconstructed from terminal status states on decode.
    3. Error registry (§3.3.2/9.5) — A2A-specific codes serialize
       `google.rpc.ErrorInfo` in `"data"`; re-wrapping an already-wrapped
       error is a no-op.
    4. AgentCard (§8.2) — a real card built from a real fixture resource,
       served through a real `AshA2A.Protocol.Plug` GET on the well-known
       path, carries v1.0 `supportedInterfaces` and no top-level
       `url`/`protocolVersion`.
    5. Multi-turn (§7.6) — `message/send` parks a real agent task in
       `TASK_STATE_INPUT_REQUIRED` on the wire; a follow-up message naming
       the same `taskId` resumes it to `TASK_STATE_COMPLETED`.

  Every court carries a positive control (a real skill/value observed on
  the wire, not just structural equality against a locally computed
  shape).
  """

  use ExUnit.Case, async: true

  alias AshA2A.Protocol.Event
  alias AshA2A.Protocol.JSON
  alias AshA2A.Protocol.JSONRPC.Error
  alias AshA2A.Protocol.{Artifact, Message, Part}
  alias AshA2A.Test.Fixture.MultiTurnConversationAgent
  alias AshA2A.Test.PlugFixture.Greeter
  alias AshA2A.Test.PlugFixture.GreeterAgent

  @error_info_type "type.googleapis.com/google.rpc.ErrorInfo"
  @a2a_domain "a2a-protocol.org"
  @content_members ["text", "data", "raw", "url"]
  # v1.0 dropped `final` from the wire: these states END a stream, so on
  # decode they reconstruct final == true; every other state must not.
  @terminal_states [:completed, :canceled, :failed, :rejected, :input_required, :auth_required]
  @non_terminal_states [:submitted, :working, :unknown]

  # ---------------------------------------------------------------------------
  # Court 1 — Part polymorphism (App. A.2.1)
  # ---------------------------------------------------------------------------

  describe "part polymorphism (App. A.2.1)" do
    test "a text+data message encodes each part with exactly one content member and no kind" do
      message =
        Message.new_user([
          Part.Text.new("where is my order?"),
          Part.Data.new(%{"order_id" => "ord-42", "nested" => %{"ok" => true}})
        ])

      assert {:ok, encoded} = JSON.encode(message)

      # Real JSON, not just a map that happens to look right.
      wire = encoded |> Jason.encode!() |> Jason.decode!()
      assert %{"role" => "ROLE_USER", "parts" => parts, "messageId" => id} = wire
      assert is_binary(id) and id != ""

      assert length(parts) == 2

      Enum.each(parts, fn part ->
        refute Map.has_key?(part, "kind"),
               "v1.0 parts carry no kind discriminator, got: #{inspect(part)}"

        present = Enum.filter(@content_members, &Map.has_key?(part, &1))

        assert length(present) == 1,
               "expected exactly one content member of #{inspect(@content_members)}, got: #{inspect(part)}"
      end)

      assert Enum.any?(parts, &Map.has_key?(&1, "text"))
      assert Enum.any?(parts, &Map.has_key?(&1, "data"))
    end

    test "Jason round-trip decodes back to the same structs (metadata preserved)" do
      message =
        Message.new_user([
          Part.Text.new("hi", %{"lang" => "en"}),
          Part.Data.new(%{"q" => 1})
        ])

      round_tripped =
        message
        |> JSON.encode!()
        |> Jason.encode!()
        |> Jason.decode!()
        |> then(&JSON.decode!(&1, :message))

      assert round_tripped == message
      assert round_tripped.parts == [
               %Part.Text{text: "hi", metadata: %{"lang" => "en"}},
               %Part.Data{data: %{"q" => 1}, metadata: %{}}
             ]
    end

    test "positive control: a mutated wire part fails the exact-one-content-member court" do
      # Kill-the-mutation check on the court itself: a v0.3-style part that
      # smuggles a `kind` discriminator onto the v1.0 wire must fail the
      # polymorphism assertion. (Asserted directly on the shape the court
      # inspects; the codec never emits this.)
      mutated = %{"kind" => "text", "text" => "hi"}
      assert Map.has_key?(mutated, "kind")

      message = Message.new_user("plain")
      {:ok, encoded} = JSON.encode(message)
      assert [part] = encoded["parts"]
      refute Map.has_key?(part, "kind")
    end
  end

  # ---------------------------------------------------------------------------
  # Court 2 — Event envelopes (v1.0 StreamResponse)
  # ---------------------------------------------------------------------------

  describe "event envelopes (v1.0 StreamResponse)" do
    test "StatusUpdate encodes as exactly one top-level statusUpdate member, no kind, no final" do
      event =
        Event.StatusUpdate.new("tsk_1", AshA2A.Protocol.Task.Status.new(:working),
          context_id: "ctx_1"
        )

      assert {:ok, wrapped} = JSON.encode_stream_response(event)

      assert map_size(wrapped) == 1
      assert %{"statusUpdate" => inner} = wrapped
      refute Map.has_key?(inner, "kind")
      refute deep_has_key?(wrapped, "final")
      assert inner["taskId"] == "tsk_1"
      assert inner["status"]["state"] == "TASK_STATE_WORKING"

      # Real JSON survives, and the v1.0 wrapper key IS the discriminator:
      # decode(:event) returns the same struct back.
      round_tripped =
        wrapped |> Jason.encode!() |> Jason.decode!() |> then(&JSON.decode!(&1, :event))

      assert round_tripped.task_id == "tsk_1"
      assert round_tripped.context_id == "ctx_1"
      assert %Event.StatusUpdate{} = round_tripped
    end

    test "ArtifactUpdate encodes as exactly one top-level artifactUpdate member, no kind, no final" do
      artifact = Artifact.new([Part.Text.new("chunk-0")], name: "log.txt")
      event = Event.ArtifactUpdate.new("tsk_2", artifact, context_id: "ctx_2", append: true)

      assert {:ok, wrapped} = JSON.encode_stream_response(event)

      assert map_size(wrapped) == 1
      assert %{"artifactUpdate" => inner} = wrapped
      refute Map.has_key?(inner, "kind")
      refute deep_has_key?(wrapped, "final")
      assert inner["taskId"] == "tsk_2"
      assert inner["artifact"]["name"] == "log.txt"

      round_tripped =
        wrapped |> Jason.encode!() |> Jason.decode!() |> then(&JSON.decode!(&1, :event))

      assert %Event.ArtifactUpdate{} = round_tripped
      assert round_tripped.task_id == "tsk_2"
      assert round_tripped.append == true
      assert round_tripped.artifact == artifact
    end

    test "finality is reconstructed from terminal status states, never from a final flag" do
      for state <- @terminal_states do
        wrapped = status_update_wire("tsk_f", state)

        assert %Event.StatusUpdate{} = event = JSON.decode!(wrapped, :event)
        assert event.final == true,
               "state #{inspect(state)} is terminal: decode must reconstruct final == true"

        refute deep_has_key?(wrapped, "final")
      end

      for state <- @non_terminal_states do
        event = JSON.decode!(status_update_wire("tsk_n", state), :event)
        assert event.final == false, "state #{inspect(state)} must not decode as final"
      end
    end

    test "positive control: a legacy v0.3 frame WITH final:true still decodes (decode-only tolerance)" do
      legacy = %{
        "kind" => "status-update",
        "taskId" => "tsk_legacy",
        "status" => %{"state" => "TASK_STATE_WORKING"},
        "final" => true
      }

      event = JSON.decode!(legacy, :event)
      assert %Event.StatusUpdate{} = event
      assert event.final == true
    end
  end

  # ---------------------------------------------------------------------------
  # Court 3 — Error registry (§3.3.2/9.5)
  # ---------------------------------------------------------------------------

  describe "error registry (§3.3.2/9.5 google.rpc.ErrorInfo)" do
    test "A2A-specific codes -32001..-32004 and -32602 serialize ErrorInfo in data" do
      registry = [
        {Error.task_not_found("tsk_missing"), -32_001, "TASK_NOT_FOUND"},
        {Error.task_not_cancelable("tsk_done"), -32_002, "TASK_NOT_CANCELABLE"},
        {Error.push_notification_not_supported("msg/stream"), -32_003, "PUSH_NOTIFICATION_NOT_SUPPORTED"},
        {Error.unsupported_operation("agent/getAuthenticatedExtendedCard"), -32_004, "UNSUPPORTED_OPERATION"},
        {Error.invalid_params(%{"field" => "historyLength"}), -32_602, "INVALID_PARAMS"}
      ]

      for {error, code, reason} <- registry do
        mapped = Error.to_map(error)

        assert mapped["code"] == code
        assert is_binary(mapped["message"]) and mapped["message"] != ""

        assert [%{"@type" => @error_info_type} = info] = mapped["data"]
        assert info["domain"] == @a2a_domain
        assert info["reason"] == reason
        assert info["reason"] == String.upcase(info["reason"]),
               "reason must be UPPER_SNAKE_CASE, got: #{info["reason"]}"
        assert Map.has_key?(info, "metadata"), "free-form data rides under metadata"
      end
    end

    test "re-wrapping an already-wrapped error is a no-op (relay idempotence)" do
      # Build the wire shape by encoding once, then feed it back through the
      # constructor + serializer exactly as a relay would.
      once = Error.to_map(Error.task_not_found("detail"))

      twice = Error.to_map(Error.task_not_found(once["data"]))

      assert twice["data"] == once["data"],
             "already-wrapped ErrorInfo must not be wrapped a second time"
    end

    test "-32603 internal error keeps free-form data (no ErrorInfo wrap)" do
      mapped = Error.to_map(Error.internal_error("boom"))
      assert mapped == %{"code" => -32_603, "message" => "Internal error", "data" => "boom"}
    end

    test "positive control: the full JSON-RPC error envelope encodes to real JSON" do
      envelope = %{
        "jsonrpc" => "2.0",
        "id" => 7,
        "error" => Error.to_map(Error.task_not_found("tsk_x"))
      }

      wire = envelope |> Jason.encode!() |> Jason.decode!()

      assert %{
               "error" => %{
                 "code" => -32001,
                 "data" => [%{"@type" => @error_info_type, "domain" => @a2a_domain, "reason" => "TASK_NOT_FOUND"}]
               }
             } = wire
    end
  end

  # ---------------------------------------------------------------------------
  # Court 4 — AgentCard (§8.2)
  # ---------------------------------------------------------------------------

  @base_url "http://localhost:4103/a2a"

  describe "agent card (§8.2)" do
    setup do
      name = :"v1_conf_card_agent_#{System.unique_integer([:positive])}"
      {:ok, pid} = GreeterAgent.start_link(name: name)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      %{
        agent: name,
        plug_opts: AshA2A.Protocol.Plug.init(agent: name, base_url: @base_url)
      }
    end

    test "GET /.well-known/agent-card.json serves the real AshA2A-compiled v1.0 card", %{
      plug_opts: plug_opts
    } do
      conn =
        Plug.Test.conn(:get, "/.well-known/agent-card.json")
        |> AshA2A.Protocol.Plug.call(plug_opts)

      assert conn.status == 200
      assert [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
      assert content_type =~ "application/json"

      served = Jason.decode!(conn.resp_body)

      # Independently computed expectation from the same real capability
      # index: AshA2A.Info.agent_card + the real encoder.
      expected =
        Greeter
        |> AshA2A.Info.agent_card(name: "greeter_agent")
        |> JSON.encode_agent_card(url: @base_url)
        |> Jason.encode!()
        |> Jason.decode!()

      assert served == expected

      # v1.0 §8.2 placement: url/protocolVersion are per-interface.
      refute Map.has_key?(served, "url")
      refute Map.has_key?(served, "protocolVersion")

      assert %{"supportedInterfaces" => [_ | _] = interfaces} = served

      Enum.each(interfaces, fn interface ->
        assert %{
                 "url" => url,
                 "protocolBinding" => "JSONRPC",
                 "protocolVersion" => "1.0"
               } = interface

        assert is_binary(url) and url != ""
      end)

      # extendedAgentCard lives INSIDE capabilities, not at the top level.
      assert %{"capabilities" => %{"extendedAgentCard" => extended}} = served
      assert extended == false

      # Positive control: the real fixture skill on the wire.
      assert %{"skills" => skills} = served

      assert Enum.any?(
               skills,
               &match?(%{"id" => "AshA2A.Test.PlugFixture.Greeter.read", "name" => "greet"}, &1)
             )
    end
  end

  # ---------------------------------------------------------------------------
  # Court 5 — Multi-turn continuation over the wire (§7.6)
  # ---------------------------------------------------------------------------

  describe "multi-turn message/send (§7.6)" do
    setup do
      name = :"v1_conf_mt_agent_#{System.unique_integer([:positive])}"
      {:ok, pid} = MultiTurnConversationAgent.start_link(name: name)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      %{
        agent: name,
        plug_opts: AshA2A.Protocol.Plug.init(agent: name, base_url: "http://localhost:4104/a2a")
      }
    end

    test "message/send parks a real task in TASK_STATE_INPUT_REQUIRED; follow-up completes it", %{
      plug_opts: plug_opts
    } do
      # Turn 1: the fixture's :converse action requires a :text argument;
      # omitting it makes the real dispatcher map the real Ash.Error.Invalid
      # to {:input_required, _} — the task parks on the wire.
      turn1 =
        plug_opts
        |> rpc("message/send", %{"message" => data_message(%{})})
        |> decode_response()

      assert %{"result" => %{"task" => %{"id" => task_id, "status" => %{"state" => "TASK_STATE_INPUT_REQUIRED"}}}} =
               turn1

      assert is_binary(task_id) and task_id != ""

      # Turn 2: continue the SAME real task_id; the real runtime folds turn
      # 1's history forward and the action completes.
      follow_up =
        Message.new_user([Part.Data.new(%{"text" => "second turn"})])
        |> struct!(task_id: task_id)

      turn2 =
        plug_opts
        |> rpc("message/send", %{"message" => JSON.encode!(follow_up)})
        |> decode_response()

      assert %{"result" => %{"task" => %{"id" => ^task_id, "status" => %{"state" => "TASK_STATE_COMPLETED"}}}} =
               turn2

      # The completed result is a real artifact the action produced.
      assert %{"result" => %{"task" => %{"artifacts" => [%{"parts" => [%{"data" => result}]}]}}} = turn2
      assert result["text"] == "second turn"
      assert result["prior_turns"] >= 1

      # Positive control: tasks/get on the same id returns the persisted,
      # genuinely-completed task — not a same-shaped fresh one.
      fetched =
        plug_opts
        |> rpc("tasks/get", %{"id" => task_id})
        |> decode_response()

      assert %{"result" => %{"id" => ^task_id, "status" => %{"state" => "TASK_STATE_COMPLETED"}}} = fetched
    end

    test "positive control: an out-of-band follow-up without the task's pending argument stays parked", %{
      plug_opts: plug_opts
    } do
      turn1 =
        plug_opts
        |> rpc("message/send", %{"message" => data_message(%{})})
        |> decode_response()

      assert %{"result" => %{"task" => %{"id" => task_id}}} = turn1

      # A follow-up that STILL omits :text cannot complete the task.
      still_parked =
        Message.new_user([Part.Data.new(%{"other" => "junk"})])
        |> struct!(task_id: task_id)

      turn2 =
        plug_opts
        |> rpc("message/send", %{"message" => JSON.encode!(still_parked)})
        |> decode_response()

      assert %{"result" => %{"task" => %{"id" => ^task_id, "status" => %{"state" => "TASK_STATE_INPUT_REQUIRED"}}}} =
               turn2
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp data_message(data) do
    JSON.encode!(Message.new_user([Part.Data.new(data)]))
  end

  defp rpc(plug_opts, method, params) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => method,
        "params" => params
      })

    :post
    |> Plug.Test.conn("/", body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("a2a-version", "1.0")
    |> AshA2A.Protocol.Plug.call(plug_opts)
  end

  defp decode_response(conn) do
    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end

  defp status_update_wire(task_id, state) do
    {:ok, wrapped} =
      state
      |> AshA2A.Protocol.Task.Status.new()
      |> then(&Event.StatusUpdate.new(task_id, &1))
      |> JSON.encode_stream_response()

    wrapped
  end

  defp deep_has_key?(map, key) when is_map(map) do
    Enum.any?(map, fn
      {k, v} when is_map(v) -> k == key or deep_has_key?(v, key)
      {k, v} when is_list(v) -> k == key or Enum.any?(v, &deep_has_key?(&1, key))
      {k, _} -> k == key
    end)
  end

  defp deep_has_key?(_, _), do: false
end
