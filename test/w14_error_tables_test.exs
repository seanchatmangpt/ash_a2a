# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.W14ErrorTablesTest do
  @moduledoc """
  Lane W14: additive spec tables and ErrorInfo builders over
  `AshA2A.Protocol.JSONRPC.Error`. Real modules, no mocks.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Protocol.JSONRPC.Error

  @info "type.googleapis.com/google.rpc.ErrorInfo"

  # code => {spec http, grpc numeric, google.rpc name}
  @spec_rows %{
    -32_001 => {404, 5, "NOT_FOUND"},
    # Pinned TCK: -32002 -> HTTP 409; -32003/-32004/-32009 -> gRPC UNIMPLEMENTED(12)
    # (the google.rpc name column is the HTTP error.status string, unchanged).
    -32_002 => {409, 9, "FAILED_PRECONDITION"},
    -32_003 => {400, 12, "FAILED_PRECONDITION"},
    -32_004 => {400, 12, "FAILED_PRECONDITION"},
    -32_005 => {400, 3, "INVALID_ARGUMENT"},
    -32_006 => {500, 13, "INTERNAL"},
    -32_007 => {400, 9, "FAILED_PRECONDITION"},
    -32_008 => {400, 9, "FAILED_PRECONDITION"},
    -32_009 => {400, 12, "FAILED_PRECONDITION"}
  }

  test "spec tables match the nine upstream rows" do
    for {code, {http, grpc, name}} <- @spec_rows do
      assert Error.spec_http_status(code) == http
      assert Error.grpc_status(code) == grpc
      assert Error.status_name_for_code(code) == name
    end

    assert Error.grpc_status(-32_603) == nil
    assert Error.spec_http_status(-32_000) == nil
  end

  test "unauthenticated / permission_denied carry ErrorInfo and keep -32600" do
    for {fun, reason} <- [unauthenticated: "UNAUTHENTICATED", permission_denied: "PERMISSION_DENIED"] do
      wire = Error.to_map(apply(Error, fun, ["nope"]))
      assert wire["code"] == -32_600

      assert [%{"@type" => @info, "domain" => "a2a-protocol.org", "reason" => ^reason} = i] =
               wire["data"]

      assert i["metadata"] == %{"detail" => "nope"}
      assert Error.status_name_for_reason(reason) == reason
    end
  end

  test "taskId and supportedVersions metadata; legacy shape unchanged without opts" do
    wire = Error.to_map(Error.task_not_found(nil, task_id: "tsk-1"))
    assert [%{"reason" => "TASK_NOT_FOUND", "metadata" => %{"taskId" => "tsk-1"}}] = wire["data"]

    wire = Error.to_map(Error.task_not_cancelable("terminal", task_id: "tsk-2"))

    assert [%{"reason" => "TASK_NOT_CANCELABLE", "metadata" => %{"taskId" => "tsk-2", "detail" => "terminal"}}] =
             wire["data"]

    wire = Error.to_map(Error.version_not_supported("9.9", supported_versions: ["1.0", "0.3"]))

    assert [%{"reason" => "VERSION_NOT_SUPPORTED", "metadata" => %{"supportedVersions" => "1.0,0.3", "detail" => "9.9"}}] =
             wire["data"]

    assert Error.to_map(Error.task_not_found()) ==
             Error.to_map(%Error{code: -32_001, message: "Task not found", data: nil})
  end

  test "server_busy variants" do
    for {kind, reason} <- [unavailable: "UNAVAILABLE", resource_exhausted: "RESOURCE_EXHAUSTED"] do
      wire = Error.to_map(Error.server_busy(nil, kind))
      assert wire["code"] == -32_000
      assert [%{"reason" => ^reason, "domain" => "a2a-protocol.org"}] = wire["data"]
    end
  end

  test "BadRequest violations builder and opt-in ToA2AError details" do
    wire = Error.to_map(Error.invalid_params_with_violations("bad", [{:status, "must be one of"}]))

    assert [%{"reason" => "INVALID_PARAMS"}, %{"@type" => "type.googleapis.com/google.rpc.BadRequest", "fieldViolations" => [%{"field" => "status", "description" => "must be one of"}]}] =
             wire["data"]

    arg = Ash.Error.Changes.InvalidArgument.exception(field: :status, message: "must be one of", value: "x")
    invalid = %Ash.Error.Invalid{errors: [arg]}

    # default: legacy single-ErrorInfo shape
    assert [_one] = AshA2A.ToA2AError.to_a2a_error(invalid, 1)["error"]["data"]

    Application.put_env(:ash_a2a, :bad_request_details, true)

    try do
      assert [%{"reason" => "INVALID_PARAMS"}, %{"fieldViolations" => [%{"field" => "status"}]}] =
               AshA2A.ToA2AError.to_a2a_error(invalid, 1)["error"]["data"]
    after
      Application.delete_env(:ash_a2a, :bad_request_details)
    end
  end
end
