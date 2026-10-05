defmodule AshA2A.Protocol.V1PaginationTest do
  @moduledoc """
  A2A v1.0 `tasks/list` + history-pagination conformance courts — real agents,
  real `message/send`-created tasks, real HTTP conns (`Plug.Test`), zero mocks
  (Chicago style).

  Spec surface (https://a2a-protocol.org/latest/specification/, ListTasks
  pagination + `historyLength`):

    * `pageSize` — integer 1..100, default 50; out-of-range MUST be refused
      (`-32602` here).
    * `pageToken`/`nextPageToken` — cursor pagination; `nextPageToken` MUST
      always be present, `""` marks the final page; tasks sorted by last
      update time descending.
    * `totalSize` — count of *matching* tasks before pagination.
    * `historyLength` (tasks/get) — at most the last N history entries;
      unset = server default (here: full history); 0 = no history.

  Reality pinned where the ported code differs from or exceeds the spec:

    * `tasks/list` also accepts `historyLength` (spec has no such field on
      ListTasksRequest) and defaults it to 0 — so every listed task's
      history is empty unless the client opts in.
    * `historyLength: 0` on `tasks/get` returns `[]` rather than omitting
      the field (spec says SHOULD omit).
    * response `pageSize` echoes the number of tasks actually returned, not
      the requested cap.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Protocol.JSON
  alias AshA2A.Protocol.Message
  alias AshA2A.Protocol.Part
  alias AshA2A.Test.Fixture.MultiTurnConversationAgent

  @base_url "http://localhost:4105/a2a"

  setup do
    name = :"v1_pag_agent_#{System.unique_integer([:positive])}"
    {:ok, pid} = MultiTurnConversationAgent.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    %{
      agent: name,
      plug_opts: AshA2A.Protocol.Plug.init(agent: name, base_url: @base_url)
    }
  end

  # ---------------------------------------------------------------------------
  # Court A — cursor pagination over tasks/list: no overlap, no gap
  # ---------------------------------------------------------------------------

  describe "tasks/list cursor pagination" do
    test "pageSize P pages resume exactly where the previous page stopped", %{
      plug_opts: plug_opts
    } do
      all = create_mixed_tasks(plug_opts, completed: 3, parked: 2)
      assert map_size(all) == 5

      # Page 1: exactly P tasks, a live cursor, and the pre-pagination total.
      page1 = list_tasks(plug_opts, %{"pageSize" => 2})

      assert %{"tasks" => t1, "totalSize" => 5, "nextPageToken" => tok1} = page1
      assert length(t1) == 2
      assert is_binary(tok1) and tok1 != "", "nextPageToken MUST be present and non-empty mid-stream"

      # Page 2 resumes from the token.
      page2 = list_tasks(plug_opts, %{"pageSize" => 2, "pageToken" => tok1})

      assert %{"tasks" => t2, "totalSize" => 5, "nextPageToken" => tok2} = page2
      assert length(t2) == 2

      # Page 3: the remainder, and the empty-string terminator the spec
      # mandates for the final page.
      page3 = list_tasks(plug_opts, %{"pageSize" => 2, "pageToken" => tok2})

      assert %{"tasks" => t3, "totalSize" => 5, "nextPageToken" => ""} = page3
      assert length(t3) == 1

      ids = ids_of(t1 ++ t2 ++ t3)
      assert ids == Enum.uniq(ids), "pages must not overlap"
      assert MapSet.new(ids) == MapSet.new(Map.keys(all)), "pages must not drop tasks (no gap)"

      # Pinned reality: the response `pageSize` is the count actually
      # returned, not the requested cap.
      assert page1["pageSize"] == length(t1)
    end

    test "a single oversized page returns everything and terminates immediately", %{
      plug_opts: plug_opts
    } do
      create_mixed_tasks(plug_opts, completed: 2, parked: 1)

      page = list_tasks(plug_opts, %{"pageSize" => 100})

      assert %{"tasks" => tasks, "totalSize" => 3, "nextPageToken" => ""} = page
      assert length(tasks) == 3
    end

    test "an unpaginated list still carries the always-present nextPageToken", %{
      plug_opts: plug_opts
    } do
      create_mixed_tasks(plug_opts, completed: 1, parked: 0)

      assert %{"tasks" => tasks, "nextPageToken" => ""} = list_tasks(plug_opts, %{})
      assert length(tasks) == 1
    end

    test "an invalid pageToken is refused with -32602", %{plug_opts: plug_opts} do
      create_mixed_tasks(plug_opts, completed: 1, parked: 0)

      error = rpc_error(plug_opts, "tasks/list", %{"pageToken" => "tok-never-issued"})

      assert error["code"] == -32_602
      assert param_detail(error) =~ "pageToken"
    end
  end

  # ---------------------------------------------------------------------------
  # Court B — pageSize bounds (server max enforcement)
  # ---------------------------------------------------------------------------

  describe "pageSize bounds" do
    test "pageSize above the server max (100) is refused with -32602 naming the field", %{
      plug_opts: plug_opts
    } do
      create_mixed_tasks(plug_opts, completed: 1, parked: 0)

      error = rpc_error(plug_opts, "tasks/list", %{"pageSize" => 101})

      assert error["code"] == -32_602
      assert param_detail(error) =~ "pageSize"
    end

    test "pageSize below the minimum (1) is refused with -32602", %{plug_opts: plug_opts} do
      error = rpc_error(plug_opts, "tasks/list", %{"pageSize" => 0})

      assert error["code"] == -32_602
      assert param_detail(error) =~ "pageSize"
    end

    test "boundary pageSize values 1 and 100 are both accepted (positive control)", %{
      plug_opts: plug_opts
    } do
      create_mixed_tasks(plug_opts, completed: 2, parked: 0)

      one = list_tasks(plug_opts, %{"pageSize" => 1})

      assert %{"tasks" => [first], "totalSize" => 2, "nextPageToken" => tok} = one
      assert is_binary(tok) and tok != ""

      hundred = list_tasks(plug_opts, %{"pageSize" => 100})

      assert %{"tasks" => both, "totalSize" => 2, "nextPageToken" => ""} = hundred
      assert MapSet.new(ids_of(both)) == MapSet.new([first["id"] | ids_of(both)])
      assert length(both) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # Court C — status filter
  # ---------------------------------------------------------------------------

  describe "status filter" do
    test "status filter returns only matching tasks and totalSize counts matches", %{
      plug_opts: plug_opts
    } do
      all = create_mixed_tasks(plug_opts, completed: 3, parked: 2)

      parked = list_tasks(plug_opts, %{"status" => "TASK_STATE_INPUT_REQUIRED"})

      assert %{"tasks" => p_tasks, "totalSize" => 2, "nextPageToken" => ""} = parked
      assert length(p_tasks) == 2
      assert Enum.all?(p_tasks, &(&1["status"]["state"] == "TASK_STATE_INPUT_REQUIRED"))
      assert MapSet.new(ids_of(p_tasks)) |> MapSet.subset?(MapSet.new(Map.keys(all)))

      completed = list_tasks(plug_opts, %{"status" => "TASK_STATE_COMPLETED"})

      assert %{"tasks" => c_tasks, "totalSize" => 3, "nextPageToken" => ""} = completed
      assert length(c_tasks) == 3
      assert Enum.all?(c_tasks, &(&1["status"]["state"] == "TASK_STATE_COMPLETED"))

      # The two filtered views partition the full set — no task lost or
      # double-counted by the filter.
      assert MapSet.new(ids_of(p_tasks) ++ ids_of(c_tasks)) == MapSet.new(Map.keys(all))
    end

    test "filter composes with pagination", %{plug_opts: plug_opts} do
      create_mixed_tasks(plug_opts, completed: 1, parked: 2)

      page =
        list_tasks(plug_opts, %{"status" => "TASK_STATE_INPUT_REQUIRED", "pageSize" => 1})

      assert %{"tasks" => [only], "totalSize" => 2, "nextPageToken" => tok} = page
      assert only["status"]["state"] == "TASK_STATE_INPUT_REQUIRED"
      assert is_binary(tok) and tok != "", "one page remains, so the cursor must be live"
    end
  end

  # ---------------------------------------------------------------------------
  # Court D — historyLength on tasks/get
  # ---------------------------------------------------------------------------

  describe "historyLength on tasks/get" do
    test "truncates to the last N entries; unset keeps the full history", %{plug_opts: plug_opts} do
      task_id = complete_two_turn_task(plug_opts)

      full = get_task(plug_opts, task_id, %{})

      assert %{"result" => %{"id" => ^task_id, "history" => history}} = full
      assert is_list(history) and length(history) >= 2,
             "a completed two-turn task must carry >= 2 history entries, got #{length(history)}"

      full_len = length(history)

      # N = 1: exactly the most recent entry.
      last_one = get_task(plug_opts, task_id, %{"historyLength" => 1})

      assert %{"result" => %{"history" => [last]}} = last_one
      assert last == List.last(history)

      # N = full: identical to the untruncated view.
      all = get_task(plug_opts, task_id, %{"historyLength" => full_len})

      assert %{"result" => %{"history" => ^history}} = all

      # N = 0: no history. The wire omits the empty `history` member
      # entirely — which is exactly what the spec's SHOULD-omit asks for.
      none = get_task(plug_opts, task_id, %{"historyLength" => 0})

      assert %{"result" => result} = none
      refute Map.has_key?(result, "history"),
             "historyLength 0 must omit the history member, got: #{inspect(result["history"])}"
    end

    test "negative historyLength is refused with -32602", %{plug_opts: plug_opts} do
      task_id = complete_two_turn_task(plug_opts)

      error = rpc_error(plug_opts, "tasks/get", %{"id" => task_id, "historyLength" => -1})

      assert error["code"] == -32_602
      assert param_detail(error) =~ "historyLength"
    end

    test "historyLength also truncates tasks/list results", %{plug_opts: plug_opts} do
      task_id = complete_two_turn_task(plug_opts)

      listed = list_tasks(plug_opts, %{"historyLength" => 1})

      assert %{"tasks" => [task]} = listed
      assert task["id"] == task_id
      assert length(task["history"]) == 1

      # Pinned reality: without an explicit historyLength, tasks/list clears
      # history entirely (server default 0, omitted when empty on the wire) —
      # the spec does not even define historyLength for ListTasksRequest.
      default = list_tasks(plug_opts, %{})

      assert %{"tasks" => [bare]} = default
      refute Map.has_key?(bare, "history")
    end
  end

  # ---------------------------------------------------------------------------
  # Court E — unknown state value refusal
  # ---------------------------------------------------------------------------

  describe "unknown status value" do
    test "an unregistered task state string is refused with -32602", %{plug_opts: plug_opts} do
      create_mixed_tasks(plug_opts, completed: 1, parked: 0)

      error = rpc_error(plug_opts, "tasks/list", %{"status" => "TASK_STATE_NOT_A_REAL_STATE"})

      assert error["code"] == -32_602
      assert param_detail(error) =~ "status"
    end

    test "a non-string status value is likewise refused", %{plug_opts: plug_opts} do
      error = rpc_error(plug_opts, "tasks/list", %{"status" => 3})

      assert error["code"] == -32_602
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp create_mixed_tasks(plug_opts, completed: n_completed, parked: n_parked) do
    completed =
      for i <- 1..n_completed//1 do
        {:ok, task} = send_message(plug_opts, %{"text" => "turn #{i}"})
        task
      end

    parked =
      for _i <- 1..n_parked//1 do
        {:ok, task} = send_message(plug_opts, %{"other" => "junk"})
        task
      end

    completed ++ parked |> Map.new(fn task -> {task["id"], task} end)
  end

  defp send_message(plug_opts, data) do
    body = rpc_body("message/send", %{"message" => data_message(data)})

    conn = post_rpc(plug_opts, body)
    assert conn.status == 200
    wire = Jason.decode!(conn.resp_body)

    assert %{"result" => %{"task" => task}} = wire, "unexpected reply: #{inspect(wire)}"
    {:ok, task}
  end

  defp complete_two_turn_task(plug_opts) do
    {:ok, %{"id" => task_id}} = send_message(plug_opts, %{})

    follow_up =
      Message.new_user([Part.Data.new(%{"text" => "finish"})])
      |> struct!(task_id: task_id)

    body = rpc_body("message/send", %{"message" => JSON.encode!(follow_up)})
    conn = post_rpc(plug_opts, body)
    assert conn.status == 200
    wire = Jason.decode!(conn.resp_body)

    assert %{"result" => %{"task" => %{"id" => ^task_id, "status" => %{"state" => "TASK_STATE_COMPLETED"}}}} =
             wire

    task_id
  end

  defp list_tasks(plug_opts, params) do
    body = rpc_body("tasks/list", params)
    conn = post_rpc(plug_opts, body)
    assert conn.status == 200
    wire = Jason.decode!(conn.resp_body)

    assert %{"result" => result} = wire, "unexpected error reply: #{inspect(wire)}"
    result
  end

  defp get_task(plug_opts, task_id, extra_params) do
    body = rpc_body("tasks/get", Map.merge(%{"id" => task_id}, extra_params))
    conn = post_rpc(plug_opts, body)
    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end

  defp rpc_error(plug_opts, method, params) do
    conn = post_rpc(plug_opts, rpc_body(method, params))
    assert conn.status == 200
    wire = Jason.decode!(conn.resp_body)

    assert %{"error" => error} = wire, "expected an error reply, got: #{inspect(wire)}"
    error
  end

  defp rpc_body(method, params) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => method,
      "params" => params
    })
  end

  defp post_rpc(plug_opts, body) do
    :post
    |> Plug.Test.conn("/", body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("a2a-version", "1.0")
    |> AshA2A.Protocol.Plug.call(plug_opts)
  end

  defp data_message(data), do: JSON.encode!(Message.new_user([Part.Data.new(data)]))

  defp ids_of(tasks), do: Enum.map(tasks, & &1["id"])

  # -32602 serializes a generic "Invalid parameters" message; the offending
  # field rides in the ErrorInfo `metadata.detail`.
  defp param_detail(error) do
    assert [%{"metadata" => %{"detail" => detail}}] = error["data"]
    detail
  end
end
