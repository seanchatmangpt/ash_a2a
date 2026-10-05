defmodule AshA2AV1ContextContinuityTest.Conversation do
  @moduledoc """
  Real fixture resource, private to this test file (kept out of the shared
  `test/support/fixture.ex` to avoid collisions with concurrent lanes), for
  the A2A v1.0 multi-turn context/history continuity court
  (`test/ash_a2a_v1_context_continuity_test.exs`).

  Its one generic `:converse` action requires `:say` and `:topic`. Supplying
  them across several real `message/send` turns (one argument per turn)
  pauses the real task `TASK_STATE_INPUT_REQUIRED` between turns, so a
  single `task_id` can carry a genuine N-turn conversation. The action body
  itself reads the threaded `context[:a2a_history]` and echoes
  `prior_turns` = the number of history entries the real dispatcher
  delivered, so history threading is asserted on action-observed evidence
  produced inside the real Ash action, not by inspecting the task struct
  from outside.
  """

  use Ash.Resource,
    domain: AshA2AV1ContextContinuityTest.ConversationDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  actions do
    action :converse, :map do
      argument(:say, :string, allow_nil?: false)
      argument(:topic, :string, allow_nil?: false)

      run(fn input, context ->
        history =
          case context do
            %{source_context: %{a2a_history: h}} when is_list(h) -> h
            _ -> Map.get(input.context || %{}, :a2a_history, [])
          end

        {:ok,
         %{
           say: input.arguments.say,
           topic: input.arguments.topic,
           prior_turns: length(history)
         }}
      end)
    end
  end

  a2a do
    skill(:converse, :converse, consequence: :observe)
  end
end

defmodule AshA2AV1ContextContinuityTest.ConversationDomain do
  @moduledoc "Real fixture domain for `AshA2AV1ContextContinuityTest.Conversation`."

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2AV1ContextContinuityTest.Conversation)
  end
end

defmodule AshA2AV1ContextContinuityTest.ConversationAgent do
  @moduledoc """
  Real `AshA2A.Agent` GenServer (the transport runtime -- owner-scoped tasks,
  off-mailbox workers) serving the fixture resource, exercised over a real
  `AshA2A.A2ATransport.Plug` on a real loopback Bandit listener.

  `execution: [mode: :inline]` is deliberate: the courts target the
  context/history machinery (`prepare_task/5` / `continue/5`), which is
  shared by both execution modes, and inline matches the serialized shape
  every other plug-level fixture in this suite uses. (The default `:async`
  mode also passes all five courts but leaves one benign teardown race at
  suite shutdown: a worker spawned microseconds before `Supervisor.stop`
  logs a `{:worker_exit, :noproc}` internal_error -- runtime noise, not a
  court subject.)
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2AV1ContextContinuityTest.Conversation,
    name: "v1_context_continuity_agent",
    require_authenticated_caller: false,
    execution: [mode: :inline]
end

defmodule AshA2AV1ContextContinuityTest do
  @moduledoc """
  A2A v1.0 context/history continuity conformance court, end to end over the
  real wire: real Bandit HTTP loopback listener -> real
  `AshA2A.A2ATransport.Plug` -> real `AshA2A.Agent` GenServer
  (`AshA2A.Transport.Runtime` task state) -> real Ash action reading the
  threaded `context[:a2a_history]`. Real JSON-RPC requests, real decoded wire
  responses, zero mocks.

  Spec semantics under court (https://a2a-protocol.org/latest/specification/):

    * `contextId` "logically groups multiple related Task and Message
      objects" (S3.4.1); agents "MAY generate a new contextId" when the
      message omits it and "MAY accept and preserve client-provided
      contextId values".
    * Follow-ups: clients "MAY use taskId (with or without contextId) to
      continue a specific task"; "Agents MUST infer contextId from the task
      if only taskId is provided"; "Agents MUST reject messages containing
      mismatching contextId and taskId" (S3.4.3/S4.1.4).
    * History: `Task.history` carries the accumulated user+agent messages of
      the conversation thread.
  """

  use ExUnit.Case, async: true

  alias AshA2A.A2ATransport.Plug, as: TransportPlug
  alias AshA2A.Protocol.JSON
  alias AshA2A.Protocol.{Message, Part}
  alias AshA2A.Test.EphemeralHttp

  setup do
    uniq = System.unique_integer([:positive])
    agent = :"v1_ctx_cont_#{uniq}"
    transport = :"a2a_transport_v1ctx_#{uniq}"
    start_supervised!({AshA2AV1ContextContinuityTest.ConversationAgent, name: agent})
    start_supervised!({AshA2A.A2ATransport, name: transport})

    http =
      EphemeralHttp.start!(
        {TransportPlug, agent: agent, base_url: "http://x/a2a", transport: transport}
      )

    %{url: http.base_url}
  end

  # -- wire helpers -----------------------------------------------------------

  defp rpc(url, method, params) do
    body = %{"jsonrpc" => "2.0", "id" => System.unique_integer([:positive]), "method" => method}

    resp_body =
      Req.post!(url, json: Map.put(body, "params", params), retry: false, receive_timeout: 10_000)
      |> Map.fetch!(:body)

    # Req decodes JSON responses itself; tolerate both the decoded map and a
    # raw binary body.
    if is_map(resp_body), do: resp_body, else: Jason.decode!(resp_body)
  end

  # Encoded v1.0 wire user message: optional structured arguments as one
  # `Part.Data` part, optional `taskId` continuation reference.
  defp user_message(data, task_id) do
    parts = if data, do: [Part.Data.new(data)], else: [Part.Text.new("go")]
    message = struct(Message.new_user(parts), task_id: task_id)
    {:ok, encoded} = JSON.encode(message)
    encoded
  end

  # One real wire turn. Sends `message/send` and returns the raw result map
  # (`{"task" => ...}` per the transport plug's StreamResponse-compatible
  # result shape).
  defp send_turn(url, params), do: rpc(url, "message/send", params)

  defp result_task(%{"result" => result}) do
    task = get_in(result, ["task"]) || result

    assert is_map(task) and is_binary(task["id"]), "no task in message/send result"
    task
  end

  defp turn(url, opts) do
    task_id = Keyword.get(opts, :task_id)
    context_id = Keyword.get(opts, :context_id)
    data = Keyword.get(opts, :data)

    params = %{"message" => user_message(data, task_id)}
    params = if context_id, do: Map.put(params, "contextId", context_id), else: params

    url
    |> send_turn(params)
    |> result_task()
  end

  defp history_of(task), do: Map.get(task, "history", [])
  defp ctx_of(task), do: Map.get(task, "contextId")

  defp artifact_data(task) do
    assert [%{"parts" => [part]}] = task["artifacts"]
    part["data"]
  end

  # A history's roles as a plain sequence, e.g. ~w(user agent user agent).
  defp role_sequence(history) do
    Enum.map(history, &String.downcase(String.replace_prefix(&1["role"], "ROLE_", "")))
  end

  describe "contextId continuity" do
    @tag :serial
    test "(a) a new task without a client contextId carries a server-generated non-empty contextId, stable across follow-ups",
         %{url: url} do
      # v1.0 S3.4.1: agents MAY generate a new contextId when the message
      # omits one. The real machinery (AshA2A.Transport.Runtime.prepare_task/5
      # -> AshA2A.Transport.Runtime.secure_context_id/0, same CSPRNG style as
      # secure_task_id/0) mints a real, non-empty conversation key on turn 1.
      task1 = turn(url, data: nil)

      assert task1["status"]["state"] == "TASK_STATE_INPUT_REQUIRED"

      ctx = ctx_of(task1)
      assert is_binary(ctx) and ctx != "", "server must generate a real contextId"

      # A follow-up on the same task_id infers the contextId from the task
      # (AshA2A.Transport.Runtime.continue/6): the conversation key is stable
      # for the task's whole life.
      task2 = turn(url, task_id: task1["id"])

      assert task2["id"] == task1["id"]
      assert ctx_of(task2) == ctx
    end

    @tag :serial
    test "(b) a client-supplied contextId is honored on turn 1 and preserved on every wire response across N turns",
         %{url: url} do
      ctx = "ctx-v24-client-alpha"
      task1 = turn(url, context_id: ctx)

      assert task1["status"]["state"] == "TASK_STATE_INPUT_REQUIRED"
      assert ctx_of(task1) == ctx

      # Turn 2: task_id follow-up carrying the same contextId -- echoed back
      # verbatim.
      task2 = turn(url, task_id: task1["id"], context_id: ctx, data: %{"say" => "hail"})
      assert ctx_of(task2) == ctx

      # Turn 3: task_id follow-up WITHOUT any contextId -- the agent must
      # infer the contextId from the task (v1.0 S4.1.4).
      task3 = turn(url, task_id: task2["id"], data: %{"say" => "hail", "topic" => "weather"})

      assert task3["status"]["state"] == "TASK_STATE_COMPLETED"
      assert ctx_of(task3) == ctx

      # The conversation is real: the completing turn's artifact was computed
      # by the real Ash action from the real threaded history of THIS
      # conversation (turn 1 user, turn 1 agent, turn 2 user, turn 2 agent,
      # turn 3 user = 5 entries).
      assert artifact_data(task3) == %{
               "say" => "hail",
               "topic" => "weather",
               "prior_turns" => 5
             }
    end

    @tag :serial
    test "(c) two conversations with different contextIds never see each other's history",
         %{url: url} do
      ctx_a = "ctx-v24-conv-a"
      ctx_b = "ctx-v24-conv-b"

      # Interleave the two conversations turn by turn on the same agent.
      a1 = turn(url, context_id: ctx_a)
      b1 = turn(url, context_id: ctx_b)

      assert a1["id"] != b1["id"]

      a2 = turn(url, task_id: a1["id"], context_id: ctx_a, data: %{"say" => "A-say"})

      # Conversation B completes ONE TURN EARLIER (both arguments in its
      # second message), so its threaded history holds exactly 3 entries
      # (turn-1 user, turn-1 agent, turn-2 user). If A's history bled into B
      # (or vice versa), either count would be wrong.
      b2 =
        turn(url, task_id: b1["id"], context_id: ctx_b, data: %{
          "say" => "B-say",
          "topic" => "B-topic"
        })

      assert b2["status"]["state"] == "TASK_STATE_COMPLETED"

      assert artifact_data(b2) == %{
               "say" => "B-say",
               "topic" => "B-topic",
               "prior_turns" => 3
             }

      # A is still mid-conversation and completes one turn later with a
      # strictly larger, A-only history (5 entries).
      a3 = turn(url, task_id: a2["id"], data: %{"say" => "A-say", "topic" => "A-topic"})

      assert artifact_data(a3) == %{
               "say" => "A-say",
               "topic" => "A-topic",
               "prior_turns" => 5
             }

      # And each task still carries its own contextId on the wire.
      assert ctx_of(a3) == ctx_a
      assert ctx_of(b2) == ctx_b
    end

    @tag :serial
    test "(d) a follow-up naming task_id from conversation A with a DIFFERENT contextId is refused with the typed not-found envelope, indistinguishable from an unknown task",
         %{url: url} do
      ctx_orig = "ctx-v24-orig"
      task1 = turn(url, context_id: ctx_orig)
      assert task1["status"]["state"] == "TASK_STATE_INPUT_REQUIRED"

      # v1.0 S3.4.3/S4.1.4: "Agents MUST reject messages containing
      # mismatching contextId and taskId". The continuation path
      # (AshA2A.Transport.Runtime.continue/6) compares the explicit,
      # non-empty request contextId against the stored task's context_id and
      # refuses the mismatch as {:error, :not_found} -- the owner-scope
      # convention: the refusal must not reveal that the task exists.
      rogue = "ctx-v24-rogue"

      mismatch =
        rpc(url, "message/send", %{
          "message" => user_message(nil, task1["id"]),
          "contextId" => rogue
        })

      assert %{"error" => mismatch_error} = mismatch

      # A genuinely unknown task id produces the IDENTICAL envelope (same
      # code, message, and data) -- indistinguishable by construction.
      unknown =
        rpc(url, "message/send", %{
          "message" => user_message(nil, "tsk-v24-unknown")
        })

      assert %{"error" => unknown_error} = unknown
      assert mismatch_error == unknown_error
      assert unknown_error["code"] == -32001

      # tasks/get agrees: the task was never touched -- its stored contextId
      # is unchanged and it remains continuable under its real context.
      %{"result" => fetched} = rpc(url, "tasks/get", %{"id" => task1["id"]})
      assert ctx_of(fetched) == ctx_orig

      task3 = turn(url, task_id: task1["id"], data: %{"say" => "s", "topic" => "t"})
      assert task3["status"]["state"] == "TASK_STATE_COMPLETED"
      assert ctx_of(task3) == ctx_orig
    end

    @tag :serial
    test "(e) turn N's task history contains every prior user+agent message in order",
         %{url: url} do
      ctx = "ctx-v24-history"
      task1 = turn(url, context_id: ctx)

      # Turn 1: the inbound user message plus the input-required agent reply.
      assert history_of(task1) |> role_sequence() == ~w(user agent)

      %{"result" => fetched1} = rpc(url, "tasks/get", %{"id" => task1["id"]})
      assert history_of(fetched1) |> role_sequence() == ~w(user agent)

      # Turn 2: append turn 2's user message (its Data part preserved) and
      # turn 2's agent reply behind turn 1's, in order.
      task2 = turn(url, task_id: task1["id"], data: %{"say" => "s1"})

      history2 = history_of(task2)
      assert role_sequence(history2) == ~w(user agent user agent)

      assert get_in(history2, [Access.at(2), "parts", Access.at(0), "data"]) == %{
               "say" => "s1"
             }

      %{"result" => fetched2} = rpc(url, "tasks/get", %{"id" => task1["id"]})
      assert history_of(fetched2) == history2

      # Turn 3 completes: the full six-message thread, oldest first.
      task3 = turn(url, task_id: task2["id"], data: %{"say" => "s1", "topic" => "t1"})

      assert task3["status"]["state"] == "TASK_STATE_COMPLETED"

      history3 = history_of(task3)
      assert role_sequence(history3) == ~w(user agent user agent user agent)

      assert get_in(history3, [Access.at(4), "parts", Access.at(0), "data"]) == %{
               "say" => "s1",
               "topic" => "t1"
             }
    end
  end
end
