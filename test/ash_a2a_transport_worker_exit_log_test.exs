defmodule AshA2A.WorkerExitLog.Note do
  @moduledoc """
  Real ETS fixture resource: `:fast` answers at once (the worker exits right
  after delivering its result), `:slow` sleeps long enough to be canceled
  while it runs.
  """

  use Ash.Resource,
    domain: AshA2A.WorkerExitLog.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  actions do
    action :fast, :map do
      run(fn _input, _context -> {:ok, %{done: true}} end)
    end

    action :slow, :map do
      run(fn _input, _context ->
        # SLEEP-CLASS: SIMULATED-SLOW-HANDLER (canceled mid-flight)
        Process.sleep(5_000)
        {:ok, %{done: true}}
      end)
    end
  end

  a2a do
    skill(:fast, :fast, consequence: :observe)
    skill(:slow, :slow, consequence: :observe)
  end
end

defmodule AshA2A.WorkerExitLog.Domain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.WorkerExitLog.Note)
  end
end

defmodule AshA2A.WorkerExitLog.Agent do
  @moduledoc false

  use AshA2A.Agent,
    resource_or_domain: AshA2A.WorkerExitLog.Note,
    name: "worker_exit_log_agent"
end

defmodule AshA2A.Transport.WorkerExitLogTest do
  @moduledoc """
  A send whose handler finishes normally, and a task canceled while its
  handler runs, are normal operation: neither logs an `internal_error`
  `{:worker_exit, _}`. Real agent (`use AshA2A.Agent`, off-mailbox workers),
  real JSON-RPC plug, real logger.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AshA2A.Protocol.{JSON, Message, Part}

  setup do
    name = :"worker_exit_log_#{System.unique_integer([:positive])}"
    {:ok, pid} = AshA2A.WorkerExitLog.Agent.start_link(name: name)

    on_exit(fn ->
      try do
        AshA2A.TestSupport.SafeStop.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    %{plug_opts: AshA2A.Protocol.Plug.init(agent: name, base_url: "http://localhost:4104/a2a")}
  end

  defp rpc(plug_opts, method, params) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => method,
        "params" => params
      })

    conn =
      :post
      |> Plug.Test.conn("/", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("a2a-version", "1.0")
      |> AshA2A.Protocol.Plug.call(plug_opts)

    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end

  defp send_params(skill, extra \\ %{}) do
    message =
      [Part.Data.new(%{})]
      |> Message.new_user()
      |> JSON.encode!()
      |> Map.put("metadata", %{"skill" => skill})

    Map.merge(%{"message" => message}, extra)
  end

  defp task_of(%{"result" => %{"task" => task}}), do: task
  defp task_of(%{"result" => %{"id" => _} = task}), do: task

  test "sends that complete normally log no worker_exit error", %{plug_opts: plug_opts} do
    log =
      capture_log(fn ->
        for _ <- 1..300 do
          task = plug_opts |> rpc("message/send", send_params("fast")) |> task_of()
          assert task["status"]["state"] == "TASK_STATE_COMPLETED"
        end

        # The worker watchers report asynchronously; let any report land.
        Process.sleep(100)
      end)

    refute log =~ "worker_exit"
    refute log =~ "internal_error"
  end

  test "canceling a task while its handler runs logs no worker_exit error",
       %{plug_opts: plug_opts} do
    log =
      capture_log(fn ->
        task =
          plug_opts
          |> rpc(
            "message/send",
            send_params("slow", %{"configuration" => %{"returnImmediately" => true}})
          )
          |> task_of()

        canceled = plug_opts |> rpc("tasks/cancel", %{"id" => task["id"]}) |> task_of()
        assert canceled["status"]["state"] == "TASK_STATE_CANCELED"
        Process.sleep(100)
      end)

    refute log =~ "worker_exit"
    refute log =~ "internal_error"
  end
end
