# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.V1AuthRequired.Fixture do
  @moduledoc """
  Real ETS fixture resource backing the transport-runtime agent below. Its
  generic action is never dispatched (the agent overrides `handle_message/2`
  to emit the direct auth-contract error shape), but the
  `use AshA2A.Agent` card build reads its compiled capability index, exactly
  like the `AshA2A.V1Cancellation.*` fixtures in
  `test/ash_a2a_v1_cancellation_test.exs`.
  """

  use Ash.Resource,
    domain: AshA2A.V1AuthRequired.FixtureDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  actions do
    action :converse, :map do
      run(fn _input, _context ->
        {:ok, %{text: "ok"}}
      end)
    end
  end

  a2a do
    skill(:converse, :converse, consequence: :observe)
  end
end

defmodule AshA2A.V1AuthRequired.FixtureDomain do
  @moduledoc false

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.V1AuthRequired.Fixture)
  end
end

defmodule AshA2A.V1AuthRequired.TransportAgent do
  @moduledoc """
  Real `use AshA2A.Agent` GenServer whose `handle_message/2` overrides the
  generated dispatcher route and emits the exact direct auth-contract error
  shapes (`AshA2A.Protocol.Agent.Runtime.auth_failure?/1`'s vocabulary):

  * `{:error, {:auth_required, "credentials expired"}}` -- the parked,
    resumable `:auth_required` producer.
  * a genuine `raise` -- the terminal `:failed` control (the off-mailbox
    worker's DOWN becomes a typed `SafeError` internal error).

  The override changes WHO classifies (this module emits the tuple; the
  runtime's own classifier binds it), not the machinery under test: the
  message still runs the full `AshA2A.Transport.Runtime` path --
  `handle_message_call/6` -> `prepare_task/5` -> `spawn_worker` ->
  `run_handler/3` -> `finish/5` -> `apply_reply/2` -- which carries the
  transport-side twin of the auth classifier and the SEC-08 redaction the
  protocol-agent path lacks. (The Ash-dispatcher route cannot produce this
  tuple: `Ash.Error.to_error_class/2` wraps a generic action's
  `{:error, term}` before `AshA2A.Dispatcher.to_reply/1` ever sees it.)
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.V1AuthRequired.Fixture,
    name: "v1_auth_required_transport_agent"

  @impl AshA2A.Protocol.Agent
  def handle_message(message, _context) do
    case AshA2A.Protocol.Message.text(message) do
      "expired" ->
        {:error, {:auth_required, "credentials expired"}}

      "raise" ->
        raise "disk on fire"

      text ->
        {:reply, [AshA2A.Protocol.Part.Text.new("ok: " <> text)]}
    end
  end
end

defmodule AshA2A.V1AuthRequired.WireAgent do
  @moduledoc """
  Real `use AshA2A.Agent` GenServer fronted by the REAL
  `AshA2A.Protocol.Plug` + `AshA2A.Protocol.Plug.Auth` HTTP pipeline for the
  full-flow wire court. Its `handle_message/2` override emits the exact
  `{:error, {:auth_required, reason}}` producer shape, so the transport
  runtime's `apply_reply/2` auth arm parks the task `:auth_required` behind
  a genuinely authenticated HTTP request.
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.V1AuthRequired.Fixture,
    name: "v1_auth_required_wire_agent"

  @impl AshA2A.Protocol.Agent
  def handle_message(message, _context) do
    case AshA2A.Protocol.Message.text(message) do
      "expired" ->
        {:error, {:auth_required, "credentials expired"}}

      text ->
        {:reply, [AshA2A.Protocol.Part.Text.new("ok: " <> text)]}
    end
  end
end

defmodule AshA2A.Protocol.V1AuthRequiredStateTest do
  @moduledoc """
  v1.0 AUTH_REQUIRED non-terminal state: real producer proof.

  Companion to `AshA2A.Protocol.V1RejectedStateTest` (terminal `:rejected`):
  where a refusal-before-effect parks a task terminally, a credentials gap
  must park it RESUMABLY (spec §3.4: the client supplies credentials and
  continues via the same task id). This file proves the landed producer: a
  handler emitting `{:error, {:auth_required, reason}}` drives a real,
  supervised `AshA2A.Protocol.Agent` task to the real non-terminal
  `:auth_required` state, encodes on the wire as
  `TASK_STATE_AUTH_REQUIRED`, round-trips the real codec, resumes to
  completion on a follow-up message with the same task id, agrees with
  `AshA2A.Protocol.Task.terminal?/1`, and stays cancelable; while a genuine
  `raise` still lands terminal `:failed` (regression control). The same
  courts are replayed through the SECOND classifier copy -- the
  `AshA2A.Transport.Runtime` `apply_reply/2` path behind `use AshA2A.Agent`
  -- which additionally redacts the reason (SEC-08).

  Chicago-style: real GenServers under real supervision, real `call/3`
  traffic in real worker processes, real state-based assertions on the
  returned and re-fetched task structs, and the real wire codec -- no
  Mock/mox/patch/monkeypatch.
  """

  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias AshA2A.Protocol.{JSON, Message, Part, Task}

  defmodule AuthAgent do
    @moduledoc """
    Real `AshA2A.Protocol.Agent` whose `handle_message/2` emits the exact
    direct auth-contract error shapes the real dispatch machinery
    classifies (`AshA2A.Protocol.Agent.Runtime.auth_failure?/1`):

    * `{:error, {:auth_required, _}}` -- the parked, resumable
      `:auth_required` producer.
    * a genuine `raise` -- attempted-and-errored, the `:failed` control
      (the task worker's DOWN is converted to a typed `SafeError` and
      classified terminal `:failed`).
    """

    use AshA2A.Protocol.Agent,
      name: "v1_auth_required_state_agent",
      description: "Produces the v1.0 AUTH_REQUIRED non-terminal state from real auth failures.",
      skills: [
        %{
          id: "greet",
          name: "greet",
          description: "Echoes the request text back.",
          tags: []
        }
      ]

    @impl AshA2A.Protocol.Agent
    def handle_message(message, _context) do
      case Message.text(message) do
        "expired" ->
          # The exact credentials-gap shape the direct protocol-agent
          # contract documents (protocol/agent/runtime.ex auth_failure?/1).
          {:error, {:auth_required, "credentials expired"}}

        "raise" ->
          # Attempted-and-errored: the handler ran and crashed mid-run.
          raise "disk on fire"

        text ->
          {:reply, [Part.Text.new("ok: " <> text)]}
      end
    end
  end

  setup do
    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [AuthAgent])

    :ok
  end

  defp call(text, opts \\ []), do: AuthAgent.call(AuthAgent, Message.new_user(text), opts)

  defp start_transport_agent do
    name = :"v1_auth_required_transport_#{System.unique_integer([:positive])}"
    {:ok, pid} = AshA2A.V1AuthRequired.TransportAgent.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    name
  end

  # ---------------------------------------------------------------------------
  # Protocol-agent path (AshA2A.Protocol.Agent.Runtime.handle_reply/2)
  # ---------------------------------------------------------------------------

  test "auth-class error parks the task non-terminal :auth_required" do
    assert {:ok, task} = call("expired")

    assert task.status.state == :auth_required
    refute Task.terminal?(task)

    # The reason is the wire-visible status message (unredacted on this
    # internal path -- redaction is the transport path's job).
    assert %Message{role: :agent} = status_msg = task.status.message
    [text_part] = status_msg.parts
    assert text_part.text =~ "Auth required:"
    assert text_part.text =~ "credentials expired"

    # Parked in the agent's real state, not just returned transiently.
    assert {:ok, %Task{status: %AshA2A.Protocol.Task.Status{state: :auth_required}}} =
             AuthAgent.get_task(AuthAgent, task.id)
  end

  test "auth_required task encodes on the wire as TASK_STATE_AUTH_REQUIRED" do
    assert {:ok, task} = call("expired")

    assert {:ok, encoded} = JSON.encode(task)
    assert encoded["status"]["state"] == "TASK_STATE_AUTH_REQUIRED"

    # The wire state round-trips back through the real codec.
    assert {:ok, decoded} = JSON.decode(encoded, :task)
    assert decoded.status.state == :auth_required

    # And survives a real Jason encoding of the whole wire map.
    assert Jason.encode!(encoded) =~ "TASK_STATE_AUTH_REQUIRED"
  end

  test "follow-up message with the same task id resumes the parked task" do
    assert {:ok, parked} = call("expired")
    assert parked.status.state == :auth_required

    assert {:ok, resumed} =
             call("here are fresh credentials", task_id: parked.id)

    # The parked task left :auth_required and ran to completion.
    assert resumed.status.state == :completed
    assert resumed.id == parked.id
    assert Task.terminal?(resumed)

    # Persisted as completed in the agent's real state.
    assert {:ok, %Task{status: %AshA2A.Protocol.Task.Status{state: :completed}}} =
             AuthAgent.get_task(AuthAgent, parked.id)
  end

  test "terminal?/1 agrees: :auth_required is non-terminal, :failed is not" do
    assert {:ok, parked} = call("expired")
    refute Task.terminal?(parked)

    failed = raise_on_continuation()
    assert Task.terminal?(failed)
  end

  # Pinned real behavior (protocol agent path): a handler `raise` on a NEW
  # task never persists a task at all -- the monitored task worker's DOWN is
  # converted to a typed redacted error (`SafeError.internal/3`) and the
  # caller gets `{:error, %{code: :internal_error, ref}}`. The `:failed`
  # landing is real only for a task the agent already holds (a continuation).
  test "a genuine raise on a new task returns a typed internal_error, not a task" do
    assert {:error, %{code: :internal_error, ref: ref}} = call("raise")
    assert is_binary(ref) and ref != ""
  end

  test "a genuine raise on a continuation lands the held task terminal :failed (regression control)" do
    failed = raise_on_continuation()

    assert failed.status.state == :failed
    assert Task.terminal?(failed)

    assert %Message{role: :agent} = status_msg = failed.status.message
    [text_part] = status_msg.parts
    assert text_part.text =~ "Error:"

    assert {:ok, %Task{status: %AshA2A.Protocol.Task.Status{state: :failed}}} =
             AuthAgent.get_task(AuthAgent, failed.id)
  end

  # Parks a real task `:auth_required` first, then raises on its continuation
  # -- the task the agent holds is failed terminally by the worker DOWN.
  defp raise_on_continuation do
    assert {:ok, parked} = call("expired")
    assert parked.status.state == :auth_required

    assert {:ok, failed} = call("raise", task_id: parked.id)
    failed
  end

  # Pinned real behavior: the cancel guard refuses only terminal states
  # (`:completed`/`:failed`/`:rejected`, plus the idempotent `:canceled`),
  # so a parked non-terminal `:auth_required` task goes to the real cancel
  # hook and cancels -- a parked task is not in flight, so refusing the
  # cancel would strand it with no other exit.
  test "a parked :auth_required task is cancelable (non-terminal cancel guard)" do
    assert {:ok, parked} = call("expired")
    assert parked.status.state == :auth_required

    assert :ok = AuthAgent.cancel(AuthAgent, parked.id)

    assert {:ok, %Task{status: %AshA2A.Protocol.Task.Status{state: :canceled}}} =
             AuthAgent.get_task(AuthAgent, parked.id)
  end

  # The vocabulary producer map (lib/ash_a2a/task_lifecycle.ex) names
  # `:auth_required` as parked-resumable; pin it beside the real producer.
  test "the lifecycle vocabulary names :auth_required as a real state" do
    assert :auth_required in AshA2A.TaskLifecycle.states()
  end

  # ---------------------------------------------------------------------------
  # Transport-runtime path (AshA2A.Transport.Runtime.apply_reply/2), the
  # second classifier copy behind `use AshA2A.Agent`
  # ---------------------------------------------------------------------------

  test "transport runtime also parks the task non-terminal :auth_required (redacted)" do
    agent = start_transport_agent()

    assert {:ok, task} =
             AshA2A.V1AuthRequired.TransportAgent.call(agent, Message.new_user("expired"))

    assert task.status.state == :auth_required
    refute Task.terminal?(task)

    # SEC-08: the transport path redacts the reason before it becomes the
    # wire-visible status message.
    assert %Message{role: :agent} = status_msg = task.status.message
    [text_part] = status_msg.parts
    assert text_part.text =~ "Auth required:"
    assert text_part.text =~ "auth_required"

    assert {:ok, %Task{status: %AshA2A.Protocol.Task.Status{state: :auth_required}}} =
             AshA2A.V1AuthRequired.TransportAgent.get_task(agent, task.id)
  end

  test "transport runtime also encodes TASK_STATE_AUTH_REQUIRED on the wire" do
    agent = start_transport_agent()

    assert {:ok, task} =
             AshA2A.V1AuthRequired.TransportAgent.call(agent, Message.new_user("expired"))

    assert {:ok, encoded} = JSON.encode(task)
    assert encoded["status"]["state"] == "TASK_STATE_AUTH_REQUIRED"

    assert {:ok, decoded} = JSON.decode(encoded, :task)
    assert decoded.status.state == :auth_required
  end

  test "transport runtime resumes the parked task on the same task id" do
    agent = start_transport_agent()

    assert {:ok, parked} =
             AshA2A.V1AuthRequired.TransportAgent.call(agent, Message.new_user("expired"))
    assert parked.status.state == :auth_required

    assert {:ok, resumed} =
             AshA2A.V1AuthRequired.TransportAgent.call(
               agent,
               Message.new_user("here are fresh credentials"),
               task_id: parked.id
             )

    assert resumed.status.state == :completed
    assert resumed.id == parked.id

    assert {:ok, %Task{status: %AshA2A.Protocol.Task.Status{state: :completed}}} =
             AshA2A.V1AuthRequired.TransportAgent.get_task(agent, parked.id)
  end

  test "transport runtime: a genuine raise still lands terminal :failed (regression control)" do
    agent = start_transport_agent()

    assert {:ok, task} =
             AshA2A.V1AuthRequired.TransportAgent.call(agent, Message.new_user("raise"))

    assert task.status.state == :failed
    assert Task.terminal?(task)
  end

  # ---------------------------------------------------------------------------
  # Full-flow wire court: RFC 7235 challenge (HTTP layer) joined to the
  # wire-visible TASK_STATE_AUTH_REQUIRED task and its re-auth resume, all
  # through the real Plug.Auth -> Protocol.Plug -> agent pipeline.
  # ---------------------------------------------------------------------------

  setup :start_wire_agent

  def start_wire_agent(_context) do
    name = :"v1_auth_required_wire_#{System.unique_integer([:positive])}"
    {:ok, pid} = AshA2A.V1AuthRequired.WireAgent.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {:ok, agent: name}
  end

  # Real verify callback: only the well-formed bearer token authenticates.
  defp wire_verify("bearer_auth", "x13-bearer-token", _conn),
    do: {:ok, %{id: "x13-user", tenant: "acme"}}

  defp wire_verify(_scheme, _credential, _conn), do: {:error, "invalid credentials"}

  # Builds the conn->pipeline runner from the context's uniquely-named agent.
  defp run_wire(conn, agent) do
    auth_opts =
      AshA2A.Protocol.Plug.Auth.init(
        schemes: %{"bearer_auth" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}},
        verify: &wire_verify/3
      )

    plug_opts =
      AshA2A.Protocol.Plug.init(
        agent: agent,
        base_url: "http://localhost:4000/a2a"
      )

    conn
    |> AshA2A.Protocol.Plug.Auth.call(auth_opts)
    |> then(fn conn ->
      if conn.halted, do: conn, else: AshA2A.Protocol.Plug.call(conn, plug_opts)
    end)
  end

  defp wire_bearer_conn(body, agent) do
    conn(:post, "/", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer x13-bearer-token")
    |> run_wire(agent)
  end

  defp wire_unauth_conn(body, agent) do
    conn(:post, "/", body)
    |> put_req_header("content-type", "application/json")
    |> run_wire(agent)
  end

  defp wire_send_body(text, task_id \\ nil) do
    {:ok, message_json} = AshA2A.Protocol.JSON.encode(Message.new_user(text))

    message_json =
      if task_id, do: Map.put(message_json, "taskId", task_id), else: message_json

    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => "req-1",
      "method" => "message/send",
      "params" => %{"message" => message_json}
    })
  end

  defp wire_tasks_get_body(task_id) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => "req-2",
      "method" => "tasks/get",
      "params" => %{"id" => task_id}
    })
  end

  test "full flow: unauthenticated message/send gets the RFC 7235 challenge and no task is reachable", %{agent: agent} do
    conn = wire_unauth_conn(wire_send_body("expired"), agent)

    assert conn.halted
    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") == [~s(Bearer realm="a2a")]
    assert Jason.decode!(conn.resp_body) == %{"error" => "Unauthorized"}
  end

  test "full flow: authenticated auth-failing request parks a wire-visible redacted TASK_STATE_AUTH_REQUIRED task", %{agent: agent} do
    conn = wire_bearer_conn(wire_send_body("expired"), agent)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert %{"result" => %{"task" => task}} = body

    # Exact v1.0 enum spelling on the wire.
    assert task["status"]["state"] == "TASK_STATE_AUTH_REQUIRED"
    assert is_binary(task["id"]) and task["id"] != ""

    # SEC-08 on the wire: the reason never leaks; the redacted status
    # message is the only wire-visible trace of the credentials gap.
    assert %{"parts" => [%{"text" => text}]} = task["status"]["message"]
    assert text =~ "Auth required:"
    refute text =~ "credentials expired"

    # Non-terminal through the real codec (resumable, not failed).
    assert {:ok, decoded} = AshA2A.Protocol.JSON.decode(task, :task)
    refute AshA2A.Protocol.Task.terminal?(decoded)
  end

  test "full flow: the parked task is re-fetchable in state AUTH_REQUIRED and resumes to completed on the same task id", %{agent: agent} do
    conn = wire_bearer_conn(wire_send_body("expired"), agent)
    body = Jason.decode!(conn.resp_body)
    assert %{"result" => %{"task" => %{"id" => parked_id}}} = body

    # Re-fetch over the wire: still parked AUTH_REQUIRED.
    get_conn = wire_bearer_conn(wire_tasks_get_body(parked_id), agent)
    assert get_conn.status == 200
    get_body = Jason.decode!(get_conn.resp_body)
    assert %{"result" => %{"status" => %{"state" => "TASK_STATE_AUTH_REQUIRED"}}} = get_body

    # Re-auth continue: a follow-up message carrying the SAME task id runs
    # the parked task to completion.
    resume_conn = wire_bearer_conn(wire_send_body("here are fresh credentials", parked_id), agent)
    assert resume_conn.status == 200
    resume_body = Jason.decode!(resume_conn.resp_body)
    assert %{"result" => %{"task" => resumed}} = resume_body

    assert resumed["status"]["state"] == "TASK_STATE_COMPLETED"
    assert resumed["id"] == parked_id
  end
end
