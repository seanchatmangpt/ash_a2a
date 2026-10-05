# ---------------------------------------------------------------------------
# In-file real fixtures (real ETS Ash resources, real agents)
# ---------------------------------------------------------------------------

defmodule AshA2A.V1Cancellation.Completable do
  @moduledoc """
  Real ETS fixture resource whose one generic action `:converse` requires a
  `:text` argument: omitting it parks the task in `:input_required`
  (courts d/e), supplying it completes the task (court a).
  """

  use Ash.Resource,
    domain: AshA2A.V1Cancellation.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  actions do
    action :converse, :map do
      argument(:text, :string, allow_nil?: false)

      run(fn input, _context ->
        {:ok, %{text: input.arguments.text}}
      end)
    end
  end

  a2a do
    skill(:converse, :converse, consequence: :observe)
  end
end

defmodule AshA2A.V1Cancellation.Domain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.V1Cancellation.Completable)
    resource(AshA2A.V1Cancellation.Slow)
  end
end

defmodule AshA2A.V1Cancellation.Slow do
  @moduledoc """
  Real ETS fixture resource whose one generic action `:slow` genuinely
  sleeps for 1000ms in the real worker process — a real in-flight handler,
  not a stub. The 1000ms window is what makes the court's cancel-while-
  in-flight race deterministically observable: the cancel RPC is issued
  from the test process while the send is still blocked on the worker.
  """

  use Ash.Resource,
    domain: AshA2A.V1Cancellation.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  actions do
    action :slow, :map do
      run(fn _input, _context ->
        Process.sleep(1000)
        {:ok, %{done: true}}
      end)
    end
  end

  a2a do
    skill(:slow, :slow, consequence: :observe)
  end
end

defmodule AshA2A.V1Cancellation.CompletableAgent do
  @moduledoc false

  use AshA2A.Agent,
    resource_or_domain: AshA2A.V1Cancellation.Completable,
    name: "v1_cancellation_completable_agent"
end

defmodule AshA2A.V1Cancellation.SlowAgent do
  @moduledoc false

  use AshA2A.Agent,
    resource_or_domain: AshA2A.V1Cancellation.Slow,
    name: "v1_cancellation_slow_agent"
end

defmodule AshA2A.Protocol.V1CancellationConformanceTest do
  @moduledoc """
  A2A v1.0 wire-level cancellation conformance courts — real codecs, real
  agents (`use AshA2A.Agent`, i.e. the `AshA2A.Transport.Runtime`-backed
  off-mailbox execution runtime), real HTTP conns (`Plug.Test`), zero mocks
  (Chicago style). Companion to `AshA2A.Protocol.V1ConformanceTest`
  (court 5 covers multi-turn, not cancellation) and
  `AshA2A.CancelInflightTest` (agent-level streaming interrupt, not the wire
  error contract).

  Five courts over the normative v1.0 cancellation contract
  (§3.1.5 Cancel Task, §3.3.1 idempotency, §3.3.2 error registry):

    (a) cancel a COMPLETED task → `-32002 TaskNotCancelable` (terminal
        states are not cancelable);
    (b) cancel a WORKING task whose real handler is genuinely in flight
        (a slow `Process.sleep` handler running in a real off-mailbox
        worker) → the repo's documented race-safety refusal
        (`AshA2A.Transport.Runtime.in_flight?/1` → `:not_cancelable`,
        `lib/ash_a2a/agent.ex:149-153`) → wire `-32002`;
    (c) cancel an UNKNOWN task id → `-32001 TaskNotFound`;
    (d) cancel a task parked in INPUT_REQUIRED (non-terminal, no handler
        running) → wire `TASK_STATE_CANCELED`; a follow-up message naming
        the canceled task_id is refused (pinned reality);
    (e) double cancel → the second attempt is idempotent success: 200/ok
        with the `TASK_STATE_CANCELED` task (spec §3.3.1).

  Every court carries a positive control (tasks/get before/after showing the
  real terminal state, or a real artifact produced by the fixture's real
  action).

  ## Spec-vs-reality notes (pinned, not papered over)

  * **Idempotency (§3.3.1):** the spec says "Cancel Task operations are
    idempotent — multiple cancellation requests have the same effect" and
    that a repeat "MAY return TaskNotFoundError if the task has already been
    canceled and purged". Reality: the repo keeps canceled tasks in its task
    store (no purge), so the second cancel of an already-canceled task is
    idempotent success — the canceled task is returned (`:ok` at the agent
    surface, 200 with the `TASK_STATE_CANCELED` task on the wire). Other
    terminal states stay `-32002 TaskNotCancelable`. Pinned as conformance
    (court e).
  * **In-flight cancel:** the spec says the server "will attempt to cancel
    the task, but success is not guaranteed". Reality: the repo refuses
    outright with `-32002` while a worker is in flight, on the documented
    grounds that reporting `:canceled` while the handler's effect may still
    commit would be a false standing. Pinned as reality (court b).
  * **Continuing a canceled task:** the spec is silent; the repo refuses
    with `:not_continuable` → `-32004 UNSUPPORTED_OPERATION` (court d).
  """

  use ExUnit.Case, async: true

  alias AshA2A.Protocol.JSON
  alias AshA2A.Protocol.{Message, Part}

  # ---------------------------------------------------------------------------
  # Shared setup / helpers
  # ---------------------------------------------------------------------------

  @error_info_type "type.googleapis.com/google.rpc.ErrorInfo"
  @a2a_domain "a2a-protocol.org"

  defp start_agent(agent_module) do
    name = :"v1_cancellation_#{System.unique_integer([:positive])}"
    {:ok, pid} = agent_module.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    %{agent: name, plug_opts: AshA2A.Protocol.Plug.init(agent: name, base_url: "http://localhost:4104/a2a")}
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

  defp data_message(data) do
    JSON.encode!(Message.new_user([Part.Data.new(data)]))
  end

  # The exact `google.rpc.ErrorInfo`-carrying error shape the A2A v1.0
  # registry (§3.3.2/9.5) requires for A2A-specific codes.
  defp assert_wire_error(response, code, reason) do
    assert %{"error" => error} = response
    assert error["code"] == code
    assert is_binary(error["message"]) and error["message"] != ""
    assert [%{"@type" => @error_info_type, "domain" => @a2a_domain, "reason" => ^reason} | _] =
             error["data"]

    error
  end

  # ---------------------------------------------------------------------------
  # Court (a) — cancel a COMPLETED task → -32002 TaskNotCancelable
  # ---------------------------------------------------------------------------

  describe "court (a): cancel a completed task" do
    test "tasks/cancel on a COMPLETED task is refused -32002 TASK_NOT_CANCELABLE", %{} do
      %{agent: _agent, plug_opts: plug_opts} = start_agent(AshA2A.V1Cancellation.CompletableAgent)

      # Real completed task: the fixture's real :converse action ran and
      # produced a real artifact.
      done =
        plug_opts
        |> rpc("message/send", %{"message" => data_message(%{"text" => "finish me"})})
        |> decode_response()

      assert %{"result" => %{"task" => %{"id" => task_id, "status" => %{"state" => "TASK_STATE_COMPLETED"}}}} =
               done

      # Positive control: tasks/get shows the task genuinely terminal.
      fetched =
        plug_opts
        |> rpc("tasks/get", %{"id" => task_id})
        |> decode_response()

      assert %{"result" => %{"id" => ^task_id, "status" => %{"state" => "TASK_STATE_COMPLETED"}}} = fetched

      # The cancel attempt itself.
      canceled =
        plug_opts
        |> rpc("tasks/cancel", %{"id" => task_id})
        |> decode_response()

      assert_wire_error(canceled, -32002, "TASK_NOT_CANCELABLE")

      # Positive control: the refusal changed nothing — the task is still
      # exactly as it was, completed, not canceled.
      still =
        plug_opts
        |> rpc("tasks/get", %{"id" => task_id})
        |> decode_response()

      assert %{"result" => %{"status" => %{"state" => "TASK_STATE_COMPLETED"}}} = still
    end
  end

  # ---------------------------------------------------------------------------
  # Court (b) — cancel a WORKING task with a genuinely in-flight handler
  # ---------------------------------------------------------------------------

  describe "court (b): cancel a working task whose handler is in flight" do
    test "tasks/cancel while the real worker sleeps is refused -32002 (race-safety refusal)", %{} do
      %{agent: agent, plug_opts: plug_opts} = start_agent(AshA2A.V1Cancellation.SlowAgent)

      # Fire the send from another process: the plug call blocks until the
      # real 1000ms handler finishes (off-mailbox async execution replies
      # at `finish`), leaving this process free to drive the wire.
      send_task =
        Task.async(fn ->
          rpc(plug_opts, "message/send", %{"message" => data_message(%{})})
        end)

      # The task transitions to :working synchronously before the worker is
      # spawned, and `tasks/list` is served from the agent's free mailbox,
      # so the working task is observable on the wire while the handler is
      # genuinely mid-flight. Poll until it appears.
      task_id =
        Enum.reduce_while(1..200, nil, fn _i, acc ->
          listed =
            plug_opts
            |> rpc("tasks/list", %{})
            |> decode_response()

          case listed do
            %{"result" => %{"tasks" => tasks}} ->
              case Enum.find(tasks, &(&1["status"]["state"] == "TASK_STATE_WORKING")) do
                %{"id" => id} ->
                  {:halt, {:ok, id}}

                nil ->
                  Process.sleep(10)
                  {:cont, acc}
              end

            _other ->
              Process.sleep(10)
              {:cont, acc}
          end
        end)

      assert {:ok, task_id} = task_id,
             "expected a TASK_STATE_WORKING task in tasks/list while the send was in flight"

      # The refusal, over the wire, while the handler is still sleeping.
      canceled =
        plug_opts
        |> rpc("tasks/cancel", %{"id" => task_id})
        |> decode_response()

      error = assert_wire_error(canceled, -32002, "TASK_NOT_CANCELABLE")

      # Pin the exact observed shape: the in-flight refusal carries the
      # agent-level `:not_cancelable` reason in the ErrorInfo metadata.
      assert [%{"metadata" => %{"detail" => ":not_cancelable"}}] = error["data"]

      # Same refusal at the agent GenServer surface (the exact atom the
      # in-flight guard in lib/ash_a2a/agent.ex:149-153 returns).
      assert {:error, :not_cancelable} = AshA2A.V1Cancellation.SlowAgent.cancel(agent, task_id)

      # Positive control: the refusal was race-safety, not cancellation.
      # The un-canceled send runs to real completion.
      send_conn = Task.await(send_task, 10_000)
      assert %{"result" => %{"task" => %{"id" => ^task_id, "status" => %{"state" => "TASK_STATE_COMPLETED"}}}} =
               decode_response(send_conn)

      fetched =
        plug_opts
        |> rpc("tasks/get", %{"id" => task_id})
        |> decode_response()

      assert %{"result" => %{"status" => %{"state" => "TASK_STATE_COMPLETED"}}} = fetched
    end
  end

  # ---------------------------------------------------------------------------
  # Court (c) — cancel an unknown task id → -32001
  # ---------------------------------------------------------------------------

  describe "court (c): cancel an unknown task" do
    test "tasks/cancel with a task id that was never issued is refused -32001 TASK_NOT_FOUND", %{} do
      %{plug_opts: plug_opts} = start_agent(AshA2A.V1Cancellation.CompletableAgent)

      missing_id = "tsk-" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

      canceled =
        plug_opts
        |> rpc("tasks/cancel", %{"id" => missing_id})
        |> decode_response()

      error = assert_wire_error(canceled, -32001, "TASK_NOT_FOUND")
      # No free-form data: a missing task carries no metadata detail.
      refute Map.has_key?(List.first(error["data"]), "metadata")

      # Positive control by contrast: tasks/get on the same id is the same
      # -32001, so a cancel of a nonexistent task is indistinguishable from
      # a get of it (owner-scoping parity, §9.5).
      fetched =
        plug_opts
        |> rpc("tasks/get", %{"id" => missing_id})
        |> decode_response()

      assert_wire_error(fetched, -32001, "TASK_NOT_FOUND")
    end
  end

  # ---------------------------------------------------------------------------
  # Court (d) — cancel a task parked in INPUT_REQUIRED → TASK_STATE_CANCELED
  # ---------------------------------------------------------------------------

  describe "court (d): cancel an input_required task" do
    test "tasks/cancel on a non-terminal INPUT_REQUIRED task succeeds; a follow-up message is refused", %{} do
      %{agent: _agent, plug_opts: plug_opts} = start_agent(AshA2A.V1Cancellation.CompletableAgent)

      # Park the task: the fixture's :converse requires :text; omit it.
      turn1 =
        plug_opts
        |> rpc("message/send", %{"message" => data_message(%{})})
        |> decode_response()

      assert %{"result" => %{"task" => %{"id" => task_id, "status" => %{"state" => "TASK_STATE_INPUT_REQUIRED"}}}} =
               turn1

      # No handler is running and the state is non-terminal: the cancel
      # succeeds and the wire task comes back TASK_STATE_CANCELED.
      canceled =
        plug_opts
        |> rpc("tasks/cancel", %{"id" => task_id})
        |> decode_response()

      assert %{"result" => %{"id" => ^task_id, "status" => %{"state" => "TASK_STATE_CANCELED"}}} = canceled

      # Positive control: tasks/get shows the real terminal state, and the
      # real AshA2A.Agent.__cancel__/2 path ran (the action-visible history
      # is intact; the task did not vanish).
      fetched =
        plug_opts
        |> rpc("tasks/get", %{"id" => task_id})
        |> decode_response()

      assert %{"result" => %{"id" => ^task_id, "status" => %{"state" => "TASK_STATE_CANCELED"}}} = fetched

      # tasks/list also reports the canceled state.
      listed =
        plug_opts
        |> rpc("tasks/list", %{})
        |> decode_response()

      assert %{"result" => %{"tasks" => tasks}} = listed
      assert Enum.any?(tasks, &(&1["id"] == task_id and &1["status"]["state"] == "TASK_STATE_CANCELED"))

      # Pinned reality: a follow-up message naming the canceled task_id is
      # refused — the runtime's terminal-continuation guard
      # (`AshA2A.Transport.Runtime.continue/5`, `:not_continuable`) maps to
      # -32004 UNSUPPORTED_OPERATION. The spec is silent on this case.
      follow_up =
        Message.new_user([Part.Data.new(%{"text" => "too late"})])
        |> struct!(task_id: task_id)

      refused =
        plug_opts
        |> rpc("message/send", %{"message" => JSON.encode!(follow_up)})
        |> decode_response()

      assert_wire_error(refused, -32004, "UNSUPPORTED_OPERATION")

      # And the refusal left the task canceled (not resurrected).
      still =
        plug_opts
        |> rpc("tasks/get", %{"id" => task_id})
        |> decode_response()

      assert %{"result" => %{"status" => %{"state" => "TASK_STATE_CANCELED"}}} = still
    end
  end

  # ---------------------------------------------------------------------------
  # Court (e) — double cancel → second attempt -32002
  # ---------------------------------------------------------------------------

  describe "court (e): double cancel" do
    test "the second cancel of an already-canceled task is idempotent success (200 with the canceled task)", %{} do
      %{agent: agent, plug_opts: plug_opts} = start_agent(AshA2A.V1Cancellation.CompletableAgent)

      # Park, then cancel: the first cancel succeeds.
      turn1 =
        plug_opts
        |> rpc("message/send", %{"message" => data_message(%{})})
        |> decode_response()

      assert %{"result" => %{"task" => %{"id" => task_id, "status" => %{"state" => "TASK_STATE_INPUT_REQUIRED"}}}} =
               turn1

      first =
        plug_opts
        |> rpc("tasks/cancel", %{"id" => task_id})
        |> decode_response()

      assert %{"result" => %{"id" => ^task_id, "status" => %{"state" => "TASK_STATE_CANCELED"}}} = first

      # The second cancel is idempotent (spec §3.3.1): 200 with the canceled
      # task — same effect as the first cancel, not a refusal.
      second =
        plug_opts
        |> rpc("tasks/cancel", %{"id" => task_id})
        |> decode_response()

      assert %{"result" => %{"id" => ^task_id, "status" => %{"state" => "TASK_STATE_CANCELED"}}} = second

      # Same idempotent success at the agent GenServer surface.
      assert :ok = AshA2A.V1Cancellation.CompletableAgent.cancel(agent, task_id)

      # A third terminal-state contrast: canceling a COMPLETED task is still
      # refused -32002 (only already-canceled is idempotent).
      turn2 =
        plug_opts
        |> rpc("message/send", %{"message" => data_message(%{"text" => "done"})})
        |> decode_response()

      assert %{"result" => %{"task" => %{"id" => done_id, "status" => %{"state" => "TASK_STATE_COMPLETED"}}}} =
               turn2

      assert_wire_error(
        plug_opts |> rpc("tasks/cancel", %{"id" => done_id}) |> decode_response(),
        -32002,
        "TASK_NOT_CANCELABLE"
      )

      # Positive control: the repeated cancel did not flip the state, and the
      # cancel hook did not run a second time (the history is unchanged).
      still =
        plug_opts
        |> rpc("tasks/get", %{"id" => task_id})
        |> decode_response()

      assert %{"result" => %{"id" => ^task_id, "status" => %{"state" => "TASK_STATE_CANCELED"}}} = still
    end
  end
end
