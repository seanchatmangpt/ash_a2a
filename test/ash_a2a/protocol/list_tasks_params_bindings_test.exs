# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ListTasksParamsBindings.Probe do
  @moduledoc false

  use Ash.Resource,
    domain: AshA2A.ListTasksParamsBindings.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  actions do
    action :whoami, :map do
      run(fn _input, _context -> {:ok, %{"subject" => nil}} end)
    end
  end

  a2a do
    skill(:whoami, :whoami, consequence: :observe)
  end
end

defmodule AshA2A.ListTasksParamsBindings.Domain do
  @moduledoc false

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.ListTasksParamsBindings.Probe)
  end
end

defmodule AshA2A.ListTasksParamsBindings.Agent do
  @moduledoc false

  use AshA2A.Agent,
    resource_or_domain: AshA2A.ListTasksParamsBindings.Probe,
    name: "list_tasks_params_bindings_agent",
    public_skills: [:whoami]
end

defmodule AshA2A.ListTasksParamsBindingsTest do
  @moduledoc """
  The same wrong-typed / out-of-range `ListTasksRequest` members are refused
  identically by the real JSON-RPC plug (-32602), the real HTTP+JSON plug
  (400 INVALID_ARGUMENT) and the real gRPC dispatch (INVALID_ARGUMENT, 3).
  No mocks.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AshA2A.Transport.Grpc.Dispatch

  # {label, JSON params (JSON-RPC and gRPC), raw query string (HTTP+JSON)}
  @bad_inputs [
    {"pageSize zero", %{"pageSize" => 0}, "pageSize=0"},
    {"pageSize too large", %{"pageSize" => 101}, "pageSize=101"},
    {"pageSize negative", %{"pageSize" => -1}, "pageSize=-1"},
    {"pageSize not a number", %{"pageSize" => "abc"}, "pageSize=abc"},
    {"historyLength negative", %{"historyLength" => -1}, "historyLength=-1"},
    {"historyLength not a number", %{"historyLength" => "x"}, "historyLength=x"},
    {"includeArtifacts not a boolean", %{"includeArtifacts" => "yes"}, "includeArtifacts=yes"},
    {"contextId not a string", %{"contextId" => 7}, nil},
    {"pageToken not a string", %{"pageToken" => %{"a" => 1}}, nil},
    {"status unknown", %{"status" => "TASK_STATE_BOGUS"}, "status=TASK_STATE_BOGUS"},
    {"status not a string", %{"status" => 3}, nil},
    {"statusTimestampAfter not a timestamp", %{"statusTimestampAfter" => "yesterday"},
     "statusTimestampAfter=yesterday"},
    {"statusTimestampAfter not a string", %{"statusTimestampAfter" => 12}, nil}
  ]

  setup do
    name = :"list_tasks_params_bindings_#{System.unique_integer([:positive])}"
    start_supervised!({AshA2A.ListTasksParamsBindings.Agent, name: name}, id: name)

    rpc_opts = AshA2A.Transport.Plug.init(agent: name, base_url: "http://127.0.0.1/a2a")
    http_opts = AshA2A.Transport.HTTPJSON.init(agent: name, base_url: "http://127.0.0.1/a2a")
    ctx = %{agent: name, opts: rpc_opts, conn: %Plug.Conn{}, principal: :anonymous}

    %{rpc_opts: rpc_opts, http_opts: http_opts, ctx: ctx}
  end

  for {label, params, query} <- @bad_inputs do
    test "JSON-RPC refuses #{label} with -32602", %{rpc_opts: opts} do
      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tasks/list",
          "params" => unquote(Macro.escape(params))
        })

      conn =
        conn(:post, "/", body)
        |> put_req_header("content-type", "application/json")
        |> AshA2A.Transport.Plug.call(opts)

      assert %{"error" => %{"code" => -32_602}} = Jason.decode!(conn.resp_body)
    end

    test "gRPC dispatch refuses #{label} with INVALID_ARGUMENT", %{ctx: ctx} do
      assert {:error, 3, _message} =
               Dispatch.call(
                 "ListTasks",
                 unquote(Macro.escape(params)),
                 AshA2A.Transport.Plug,
                 ctx
               )
    end

    if query do
      test "HTTP+JSON refuses #{label} with 400 INVALID_ARGUMENT", %{http_opts: opts} do
        conn = conn(:get, "/tasks?" <> unquote(query)) |> AshA2A.Transport.HTTPJSON.call(opts)

        assert conn.status == 400
        assert %{"error" => %{"status" => "INVALID_ARGUMENT"}} = Jason.decode!(conn.resp_body)
      end
    end
  end

  test "the shared validator and JSON.decode_list_tasks_request/1 agree" do
    for {_label, params, _query} <- @bad_inputs do
      assert {:error, message} = AshA2A.Protocol.ListTasksParams.validate(params)
      assert {:error, {:invalid_params, ^message}} =
               AshA2A.Protocol.JSON.decode_list_tasks_request(params)
    end

    assert :ok = AshA2A.Protocol.ListTasksParams.validate(%{})
    assert :ok = AshA2A.Protocol.ListTasksParams.validate(%{"pageSize" => 100, "status" => nil})
  end

  test "HTTP+JSON accepts includeArtifacts=true and =false", %{http_opts: opts} do
    for v <- ["true", "false"] do
      conn = conn(:get, "/tasks?includeArtifacts=" <> v) |> AshA2A.Transport.HTTPJSON.call(opts)
      assert conn.status == 200
    end
  end
end
