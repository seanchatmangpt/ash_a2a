# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Y4ErrorVersionTableTest do
  @moduledoc """
  Lane Y4: one table pinning every A2A error code's JSON-RPC, HTTP and gRPC row
  (pinned TCK `ERROR_BINDINGS`), plus the absent-version rule for push delivery.
  Real modules, no mocks.
  """

  use ExUnit.Case, async: true

  alias AshA2A.A2ATransport.PushDelivery
  alias AshA2A.Protocol.JSONRPC.Error
  alias AshA2A.Transport.Grpc.Dispatch

  # {constructor, jsonrpc code, http status, grpc numeric, ErrorInfo reason}
  @rows [
    {:task_not_found, -32_001, 404, 5, "TASK_NOT_FOUND"},
    {:task_not_cancelable, -32_002, 409, 9, "TASK_NOT_CANCELABLE"},
    {:push_notification_not_supported, -32_003, 400, 12, "PUSH_NOTIFICATION_NOT_SUPPORTED"},
    {:unsupported_operation, -32_004, 400, 12, "UNSUPPORTED_OPERATION"},
    {:content_type_not_supported, -32_005, 415, 3, "CONTENT_TYPE_NOT_SUPPORTED"},
    {:invalid_agent_response, -32_006, 502, 13, "INVALID_AGENT_RESPONSE"},
    {:authenticated_extended_card_not_configured, -32_007, 400, 9,
     "EXTENDED_AGENT_CARD_NOT_CONFIGURED"},
    {:extension_support_required, -32_008, 400, 9, "EXTENSION_SUPPORT_REQUIRED"},
    {:version_not_supported, -32_009, 400, 12, "VERSION_NOT_SUPPORTED"},
    {:task_generation_mismatch, -32_010, 409, 10, "TASK_GENERATION_MISMATCH"}
  ]

  test "every code: JSON-RPC code, HTTP status, gRPC status, ErrorInfo reason" do
    for {fun, code, http, grpc, reason} <- @rows do
      error = apply(Error, fun, [])
      assert error.code == code, "#{fun} code"
      assert Error.spec_http_status(code) == http, "#{code} http"
      assert Error.grpc_status(code) == grpc, "#{code} grpc"
      assert [%{"reason" => ^reason}] = Error.to_map(error)["data"], "#{code} reason"
    end
  end

  test "gRPC dispatch agrees with the table for -32005" do
    assert {:error, 3, _msg, details} = Dispatch.reason_error({:content_type_not_supported, %{}})
    assert is_list(details)
  end

  test "-32005 / -32006 follow the pinned TCK, not the old 400 / 500" do
    assert Error.spec_http_status(-32_005) == 415
    assert Error.spec_http_status(-32_006) == 502
  end

  describe "absent protocol_version (documented rule: absent == 0.3)" do
    test "push delivery with no version behaves as 0.3 (v1.1 additions stripped)" do
      payload = %{"task" => %{"id" => "t1", "generation" => 3, "timeline" => []}}

      assert {:ok, %{"task" => task}} = PushDelivery.payload_for(%{}, "task", payload)
      refute Map.has_key?(task, "generation")
      assert :skip = PushDelivery.payload_for(%{}, "message-update", payload)
      assert PushDelivery.payload_for(%{}, "task", payload) ==
               PushDelivery.payload_for(%{protocol_version: "0.3"}, "task", payload)
    end

    test "explicit 1.1 still receives the payload as logged" do
      payload = %{"task" => %{"id" => "t1", "generation" => 3}}
      assert {:ok, ^payload} = PushDelivery.payload_for(%{protocol_version: "1.1"}, "task", payload)
    end
  end
end
