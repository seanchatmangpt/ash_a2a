# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Test.Fixture.TraceNoteAgent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.TenantActorNote,
    name: "trace_note_agent"
end

defmodule AshA2A.TraceTest do
  @moduledoc """
  ZD2 court: TRACE-compliant trace export for A2A task sagas.

  Real `message/send` dispatch through the real transport plug stack
  (`AshA2A.Protocol.Plug.Auth` -> `AshA2A.Trace.Plug` ->
  `AshA2A.A2ATransport.Plug`) drives a real saga (dispatch -> authority ->
  actuation -> receipt); the exported trace must carry the full span tree
  with correct parent links and the wire task ids. Replay determinism and
  OTLP/JSON export are asserted on the same real documents. No mocks.
  """

  use ExUnit.Case, async: true

  import Plug.Conn

  alias AshA2A.A2ATransport.Plug, as: TransportPlug
  alias AshA2A.Protocol.Plug.Auth
  alias AshA2A.Test.Fixture.TenantActorNote
  alias AshA2A.Test.Fixture.TraceNoteAgent

  @schemes %{"bearer" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}}
  @identity %{id: "user-trace-1", tenant: "trace"}

  def verify("bearer", "trace-token", _conn), do: {:ok, @identity}
  def verify("bearer", "other-token", _conn), do: {:ok, %{id: "user-other", tenant: "other"}}
  def verify(_scheme, _token, _conn), do: {:error, "invalid token"}

  setup do
    uniq = System.unique_integer([:positive])
    agent = :"trace_note_agent_#{uniq}"
    transport = :"a2a_transport_trace_#{uniq}"

    start_supervised!({TraceNoteAgent, name: agent})
    start_supervised!({AshA2A.A2ATransport, name: transport})

    :ok = AshA2A.Trace.Recorder.ensure()

    AshA2A.Test.AuthorityGrantCase.grant!([{@identity, TenantActorNote, ["create_note"]}])

    %{
      agent: agent,
      transport: transport,
      auth: Auth.init(schemes: @schemes, verify: &__MODULE__.verify/3),
      trace_plug: AshA2A.Trace.Plug.init(agent: agent, transport: transport),
      transport_plug:
        TransportPlug.init(agent: agent, base_url: "http://x/a2a", transport: transport)
    }
  end

  # -- pipeline ------------------------------------------------------------------

  defp post(ctx, token, params) do
    body =
      Jason.encode!(Map.merge(%{"jsonrpc" => "2.0", "id" => 1, "method" => "message/send"}, %{params: params}))

    conn =
      Plug.Test.conn(:post, "/", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)
      |> Auth.call(ctx.auth)

    refute conn.halted

    conn
    |> AshA2A.Trace.Plug.call(ctx.trace_plug)
    |> then(fn conn -> if conn.halted, do: conn, else: TransportPlug.call(conn, ctx.transport_plug) end)
  end

  defp get_trace(ctx, token, task_id, query \\ "") do
    conn =
      Plug.Test.conn(:get, "/tasks/#{task_id}/trace#{query}")
      |> put_req_header("authorization", "Bearer " <> token)
      |> Auth.call(ctx.auth)

    refute conn.halted
    served = AshA2A.Trace.Plug.call(conn, ctx.trace_plug)
    assert served.halted
    served
  end

  defp send_create(ctx, label) do
    msg =
      %{AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(%{"body" => label})])
        | metadata: %{"skill" => "create_note"}}

    {:ok, msg_json} = AshA2A.Protocol.JSON.encode(msg)

    conn = post(ctx, "trace-token", %{"message" => msg_json})
    assert conn.status == 200

    %{"result" => %{"task" => task}} = Jason.decode!(conn.resp_body)
    assert %{"status" => %{"state" => "TASK_STATE_COMPLETED"}} = task
    task
  end

  defp span_named(doc, name), do: Enum.find(doc["spans"], &match?(%{"name" => ^name}, &1))

  # -- the court -------------------------------------------------------------------

  test "real dispatch through the transport exports the full saga span tree", ctx do
    task = send_create(ctx, "trace-saga-1")
    task_id = task["id"]

    served = get_trace(ctx, "trace-token", task_id)
    assert served.status == 200

    doc = Jason.decode!(served.resp_body)

    # deterministic identity bound to the wire task id
    assert doc["traceId"] == AshA2A.Trace.trace_id(task_id)
    assert doc["taskId"] == task_id
    assert Regex.match?(~r/\A[0-9a-f]{32}\z/, doc["traceId"])

    # full span tree, correct parent links. The real saga nests
    # task -> actuation (the command bus's actuate span) -> dispatch
    # (the dispatcher's span inside the actuation).
    assert %{"name" => "a2a.task", "spanId" => task_sid, "parentSpanId" => ""} =
             span_named(doc, "a2a.task")

    assert %{"spanId" => actuation_sid, "parentSpanId" => ^task_sid} =
             span_named(doc, "a2a.actuation")

    assert %{"parentSpanId" => ^actuation_sid} = span_named(doc, "a2a.dispatch")

    assert Enum.map(doc["spans"], & &1["name"]) == ["a2a.task", "a2a.actuation", "a2a.dispatch"]
    assert span_named(doc, "a2a.task")["kind"] == "SPAN_KIND_SERVER"

    for span <- doc["spans"] do
      assert %{"endTimeUnixNano" => t1, "startTimeUnixNano" => t0} = span
      assert String.to_integer(t1) >= String.to_integer(t0)
    end

    # envelope attributes on the task span (from the real task record)
    task_span = span_named(doc, "a2a.task")
    assert task_span["attributes"]["a2a.task.id"] == task_id
    assert task_span["attributes"]["a2a.task.context_id"] == task["contextId"]
    assert task_span["attributes"]["a2a.task.state"] == "TASK_STATE_COMPLETED"
    assert task_span["attributes"]["a2a.principal"] == "id:user-trace-1"

    # dispatch attributes from the dispatcher telemetry
    dispatch = span_named(doc, "a2a.dispatch")
    assert dispatch["attributes"]["a2a.skill"] == "create_note"
    assert dispatch["attributes"]["a2a.reply_type"] == "reply"

    # authority/actuation/receipt saga boundaries as span events on the
    # enclosing task span (the command bus fires them outside the dispatch
    # span, before/after the actuation stage)
    event_names = Enum.map(task_span["events"], & &1["name"])

    assert "authority.decision" in event_names

    authority = Enum.find(task_span["events"], &match?(%{"name" => "authority.decision"}, &1))
    assert authority["attributes"]["authority.outcome"] == "granted"

    assert "command_bus.target" in event_names
    assert "command_bus.admission" in event_names
    assert "command_bus.claim" in event_names
    assert "command_bus.prepare" in event_names
    assert "command_bus.postcondition" in event_names
    assert "command_bus.commit" in event_names
    assert "receipt.committed" in event_names

    receipt = Enum.find(task_span["events"], &match?(%{"name" => "receipt.committed"}, &1))
    assert receipt["attributes"]["receipt.terminal_status"] == "executed"
    assert receipt["attributes"]["receipt.command_id"] =~ ~r/\Amsg-/

    # TaskEvents wire log as events on the task span, with the wire task id
    wire_events = Enum.filter(task_span["events"], &match?(%{"name" => "task"}, &1))
    assert [%{"attributes" => %{"a2a.event.seq" => 1, "a2a.event.final" => true}}] = wire_events
  end

  test "replay determinism: two sagas export identical structure; repeated export is stable", ctx do
    task1 = send_create(ctx, "trace-replay-a")
    task2 = send_create(ctx, "trace-replay-b")

    {:ok, doc1} = AshA2A.Trace.export(ctx.transport, task1["id"], agent: ctx.agent)
    {:ok, doc1_again} = AshA2A.Trace.export(ctx.transport, task1["id"], agent: ctx.agent)
    {:ok, doc2} = AshA2A.Trace.export(ctx.transport, task2["id"], agent: ctx.agent)

    # same saga exported twice: identical document (timestamps are recorded once)
    assert doc1 == doc1_again

    # different task, same saga shape: identical structure modulo the
    # task-derived identity and timestamps
    assert structure(doc1) == structure(doc2)
    assert doc1["taskId"] != doc2["taskId"]
    assert doc1["traceId"] != doc2["traceId"]
    assert AshA2A.Trace.trace_id(task2["id"]) == doc2["traceId"]
  end

  test "OTLP export is valid OTLP/JSON TracesData", ctx do
    task = send_create(ctx, "trace-otlp")

    {:ok, doc} = AshA2A.Trace.export(ctx.transport, task["id"], agent: ctx.agent, format: :otlp)

    assert [%{"resource" => resource, "scopeSpans" => [scope]}] = doc["resourceSpans"]
    assert %{"key" => "service.name", "value" => %{"stringValue" => "ash_a2a"}} in resource["attributes"]

    assert scope["scope"]["name"] == "ash_a2a.trace"
    spans = scope["spans"]
    assert Enum.map(spans, & &1["name"]) == ["a2a.task", "a2a.actuation", "a2a.dispatch"]

    trace_id = AshA2A.Trace.trace_id(task["id"])

    for span <- spans do
      assert span["traceId"] == trace_id
      assert Regex.match?(~r/\A[0-9a-f]{16}\z/, span["spanId"])
      assert Regex.match?(~r/\A\d+\z/, span["startTimeUnixNano"])
      assert Regex.match?(~r/\A\d+\z/, span["endTimeUnixNano"])

      # OTLP attribute typing: key/value objects, ints as intValue
      for %{"key" => k, "value" => v} <- span["attributes"] do
        assert is_binary(k)

        assert match?(%{"stringValue" => _}, v) or match?(%{"intValue" => _}, v) or
                 match?(%{"boolValue" => _}, v)
      end
    end

    [task_span, actuation_span, dispatch_span] = spans
    assert task_span["parentSpanId"] == ""
    assert actuation_span["parentSpanId"] == task_span["spanId"]
    assert dispatch_span["parentSpanId"] == actuation_span["spanId"]

    # wire-log events survive OTLP typing (seq as intValue)
    wire = Enum.find(task_span["events"], &match?(%{"name" => "task"}, &1))
    assert wire

    assert %{"value" => %{"intValue" => 1}} =
             Enum.find(wire["attributes"], &match?(%{"key" => "a2a.event.seq"}, &1))
  end

  test "owner scope: foreign and missing tasks are 404 with the A2A task-not-found error", ctx do
    task = send_create(ctx, "trace-owner")
    task_id = task["id"]

    served = get_trace(ctx, "other-token", task_id)
    assert served.status == 404

    assert %{"error" => %{"code" => -32001}} = Jason.decode!(served.resp_body)

    served = get_trace(ctx, "trace-token", "no-such-task")
    assert served.status == 404
    assert %{"error" => %{"code" => -32001}} = Jason.decode!(served.resp_body)
  end

  test "GET trace with format=otlp serves OTLP/JSON; POST passes through the trace plug", ctx do
    task = send_create(ctx, "trace-otlp-endpoint")

    served = get_trace(ctx, "trace-token", task["id"], "?format=otlp")
    assert served.status == 200

    otlp = Jason.decode!(served.resp_body)
    assert [%{"scopeSpans" => [_ | _]}] = otlp["resourceSpans"]

    # POST dispatch already passed through AshA2A.Trace.Plug untouched in
    # every send_create/2 above; assert the passthrough explicitly for a
    # non-trace GET too (agent card path answer comes from the transport).
    conn =
      Plug.Test.conn(:get, "/.well-known/agent-card.json")
      |> Auth.call(ctx.auth)

    refute conn.halted

    conn = AshA2A.Trace.Plug.call(conn, ctx.trace_plug)
    refute conn.halted
  end

  # -- helpers ----------------------------------------------------------------------

  defp structure(doc) do
    Enum.map(doc["spans"], fn span ->
      %{
        "name" => span["name"],
        "parent" => parent_name(doc["spans"], span["parentSpanId"]),
        "kind" => span["kind"],
        "status" => span["status"],
        "attribute_keys" => attr_keys(span["attributes"]),
        "event_names" => Enum.map(span["events"], & &1["name"])
      }
    end)
  end

  defp attr_keys(attrs) when is_map(attrs) do
    attrs |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Enum.map(&elem(&1, 0)) |> Enum.sort()
  end

  defp attr_keys(_other), do: []

  defp parent_name(_spans, ""), do: nil

  defp parent_name(spans, parent_span_id) do
    case Enum.find(spans, &match?(%{"spanId" => ^parent_span_id}, &1)) do
      %{"name" => name} -> name
      _ -> parent_span_id
    end
  end
end
