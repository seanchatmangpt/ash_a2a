defmodule AshA2A.HttpJsonErrorStatusTable.Agent do
  @moduledoc """
  A real agent process (a hand-written GenServer speaking the agent call
  protocol the HTTP+JSON binding uses) that refuses every send with the A2A
  error its message names. It lets one test drive every error type of the
  binding table through the real plug.
  """

  use GenServer

  alias AshA2A.Protocol.JSONRPC.Error

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, :ok, name: Keyword.fetch!(opts, :name))

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call(:get_agent_card, _from, state) do
    {:reply, %{name: "error-table", description: "refuses by name", version: "1", skills: []},
     state}
  end

  def handle_call({:message, message, _opts}, _from, state) do
    [%{text: constructor}] = message.parts
    {:reply, {:error, apply(Error, String.to_existing_atom(constructor), [])}, state}
  end

  def handle_call(_other, _from, state), do: {:reply, {:error, :not_found}, state}
end

defmodule AshA2A.HttpJsonErrorStatusTableTest do
  @moduledoc """
  One table for every binding: `AshA2A.Protocol.JSONRPC.Error.bindings/1`.

  For every A2A error type the HTTP status the real HTTP+JSON plug serves,
  the `error.status` name in its body, the public helpers
  (`Error.http_status/1`, `Error.spec_http_status/1`, `Error.grpc_status/1`)
  and the gRPC dispatch status are the same row, and that row is the
  specification's (section 5.4; the table has the same text at tags v1.0.1
  and v1.1.0-rc, v1.1 only adds TaskGenerationMismatchError, so the answer
  does not depend on the negotiated version). Real plug, real conns, a real
  agent process; no mocks.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Protocol.JSONRPC.Error
  alias AshA2A.Transport.Grpc.Dispatch
  alias AshA2A.Transport.HTTPJSON

  # {constructor, JSON-RPC code, HTTP status, gRPC status, gRPC name, ErrorInfo reason}
  # Specification 5.4 "Error Code Mappings", v1.1.0-rc (rows 1..9 identical at v1.0.1).
  @spec_rows [
    {:task_not_found, -32_001, 404, 5, "NOT_FOUND", "TASK_NOT_FOUND"},
    {:task_not_cancelable, -32_002, 400, 9, "FAILED_PRECONDITION", "TASK_NOT_CANCELABLE"},
    {:push_notification_not_supported, -32_003, 400, 9, "FAILED_PRECONDITION",
     "PUSH_NOTIFICATION_NOT_SUPPORTED"},
    {:unsupported_operation, -32_004, 400, 9, "FAILED_PRECONDITION", "UNSUPPORTED_OPERATION"},
    {:content_type_not_supported, -32_005, 400, 3, "INVALID_ARGUMENT",
     "CONTENT_TYPE_NOT_SUPPORTED"},
    {:invalid_agent_response, -32_006, 500, 13, "INTERNAL", "INVALID_AGENT_RESPONSE"},
    {:authenticated_extended_card_not_configured, -32_007, 400, 9, "FAILED_PRECONDITION",
     "EXTENDED_AGENT_CARD_NOT_CONFIGURED"},
    {:extension_support_required, -32_008, 400, 9, "FAILED_PRECONDITION",
     "EXTENSION_SUPPORT_REQUIRED"},
    {:version_not_supported, -32_009, 400, 9, "FAILED_PRECONDITION", "VERSION_NOT_SUPPORTED"},
    {:task_generation_mismatch, -32_010, 409, 10, "ABORTED", "TASK_GENERATION_MISMATCH"}
  ]

  setup do
    agent = :"http_json_error_table_#{System.unique_integer([:positive])}"
    start_supervised!({AshA2A.HttpJsonErrorStatusTable.Agent, name: agent})
    %{opts: HTTPJSON.init(agent: agent, base_url: "http://localhost/rest")}
  end

  defp send_message(opts, constructor, version) do
    body =
      Jason.encode!(%{
        "message" => %{
          "messageId" => "m-#{System.unique_integer([:positive])}",
          "role" => "ROLE_USER",
          "parts" => [%{"text" => Atom.to_string(constructor)}]
        }
      })

    :post
    |> Plug.Test.conn("/message:send", body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("a2a-version", version)
    |> HTTPJSON.call(opts)
  end

  for version <- ["1.0", "1.1"] do
    test "A2A-Version #{version}: the served HTTP status of every error type is the table's row",
         %{opts: opts} do
      for {constructor, code, http, _grpc, name, reason} <- @spec_rows do
        conn = send_message(opts, constructor, unquote(version))

        assert conn.status == http,
               "#{constructor} (#{code}) was served HTTP #{conn.status}, the table says #{http}"

        assert conn.status == Error.http_status(code)
        assert conn.status == Error.spec_http_status(code)

        assert %{"error" => %{"code" => ^http, "status" => ^name, "details" => details}} =
                 Jason.decode!(conn.resp_body)

        assert Enum.any?(details, &(&1["reason"] == reason)),
               "#{constructor}: no ErrorInfo reason #{reason} in #{inspect(details)}"
      end
    end
  end

  test "the helpers, the JSON-RPC code, the ErrorInfo reason and the gRPC dispatch are one row" do
    for {constructor, code, http, grpc, name, reason} <- @spec_rows do
      error = apply(Error, constructor, [])
      assert error.code == code
      assert Error.bindings(:all)[code] == {http, grpc, name}
      assert Error.http_status(code) == http
      assert Error.spec_http_status(code) == http
      assert Error.grpc_code(code) == grpc
      assert Error.grpc_status(code) == grpc
      assert Error.status_name_for_code(code) == name
      assert Dispatch.status_name(grpc) == name
      assert [%{"reason" => ^reason}] = Error.to_map(error)["data"]

      assert {:error, ^grpc, _message, [_error_info]} = Dispatch.error_to_grpc(error)
    end
  end

  test "the table covers every A2A constructor and nothing answers the TCK-era values" do
    codes = for {_constructor, code, _http, _grpc, _name, _reason} <- @spec_rows, do: code
    assert Error.bindings(:a2a) |> Map.keys() |> Enum.sort() == Enum.sort(codes)
    assert Map.take(Error.bindings(:all), codes) == Error.bindings(:a2a)

    # VG-01..VG-03: 409 / 415 / 502 are in no version of section 5.4.
    assert Error.http_status(-32_002) == 400
    assert Error.http_status(-32_005) == 400
    assert Error.http_status(-32_006) == 500
    refute Enum.any?([-32_002, -32_005, -32_006], &(Error.http_status(&1) in [415, 502]))
  end

  test "the standard JSON-RPC codes are rows of the same table" do
    for {code, http, grpc} <- [
          {-32_700, 400, 3},
          {-32_600, 400, 3},
          {-32_601, 400, 12},
          {-32_602, 400, 3},
          {-32_603, 500, 13},
          {-32_000, 503, 14}
        ] do
      assert Error.http_status(code) == http
      assert Error.grpc_code(code) == grpc
      # The spec-only helpers answer for A2A error types alone.
      assert Error.spec_http_status(code) == nil
      assert Error.grpc_status(code) == nil
    end

    assert Error.http_status(-1) == nil
  end
end
