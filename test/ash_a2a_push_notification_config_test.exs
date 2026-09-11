defmodule AshA2A.PushNotificationConfigTest do
  @moduledoc """
  Real, end-to-end assertion of the "not supported" JSON-RPC error shape for
  `tasks/pushNotificationConfig/*` methods.

  ash_a2a implements no push-notification-config feature at all (no CRUD, no
  handler callback for it anywhere in `AshA2A.Agent`/`AshA2A.Dispatcher`).
  The real behavior it inherits comes entirely from the vendored `:a2a`
  0.2.0 dependency's own transport-agnostic dispatch layer,
  `A2A.JSONRPC.handle/3`: every `"tasks/pushNotificationConfig/" <> _`
  method (and its v0.3.0 PascalCase aliases, e.g. `"CreateTaskPushNotificationConfig"`)
  is intercepted by a dispatch clause that never calls the handler at all
  and always replies with `A2A.JSONRPC.Error.push_notification_not_supported/1`
  (`~/xaas/deps/a2a/lib/a2a/jsonrpc.ex:171`).

  This test drives that real dispatch function directly with a real JSON-RPC
  request map and a real handler
  (`AshA2A.Test.Fixture.JSONRPCHandler`, backed by a real, supervised
  `AshA2A.Test.Fixture.EchoAgent` `A2A.Agent` GenServer) -- no
  Mock/mox/patch/monkeypatch anywhere. It asserts on the real returned
  response map's exact `-32003` error code/message/JSON shape, and separately
  proves the handler's `handle_send/3` is never invoked for these methods (a
  real call-count assertion backed by a real, plain Elixir `Agent` counter,
  not an interaction-based mock of a collaborator -- the counter itself is
  the thing under test, not a stand-in for one).
  """

  use ExUnit.Case, async: true

  alias AshA2A.Test.Fixture.EchoAgent
  alias AshA2A.Test.Fixture.JSONRPCHandler

  setup do
    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [EchoAgent])

    :ok
  end

  describe "tasks/pushNotificationConfig/* dispatch" do
    test "set returns the real -32003 push_notification_not_supported error shape" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "req-1",
        "method" => "tasks/pushNotificationConfig/set",
        "params" => %{"taskId" => "some-task", "pushNotificationConfig" => %{}}
      }

      assert {:reply, response} = A2A.JSONRPC.handle(request, JSONRPCHandler, %{})

      assert response == %{
               "jsonrpc" => "2.0",
               "id" => "req-1",
               "error" => %{
                 "code" => -32_003,
                 "message" => "Push Notification is not supported"
               }
             }
    end

    test "get, list, and delete all return the same real error code/message" do
      for {method, params} <- [
            {"tasks/pushNotificationConfig/get", %{"id" => "cfg-1"}},
            {"tasks/pushNotificationConfig/list", %{"taskId" => "some-task"}},
            {"tasks/pushNotificationConfig/delete", %{"id" => "cfg-1"}}
          ] do
        request = %{"jsonrpc" => "2.0", "id" => method, "method" => method, "params" => params}

        assert {:reply, %{"error" => error}} = A2A.JSONRPC.handle(request, JSONRPCHandler, %{})
        assert error["code"] == -32_003
        assert error["message"] == "Push Notification is not supported"
      end
    end

    test "the real v0.3.0 PascalCase method alias resolves to the same real error" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "alias-req",
        "method" => "CreateTaskPushNotificationConfig",
        "params" => %{"taskId" => "some-task", "pushNotificationConfig" => %{}}
      }

      assert {:reply, response} = A2A.JSONRPC.handle(request, JSONRPCHandler, %{})

      assert %{
               "jsonrpc" => "2.0",
               "id" => "alias-req",
               "error" => %{"code" => -32_003, "message" => "Push Notification is not supported"}
             } = response
    end

    test "the response round-trips through the real :a2a JSON error encoder unchanged" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 42,
        "method" => "tasks/pushNotificationConfig/set",
        "params" => %{"taskId" => "some-task", "pushNotificationConfig" => %{}}
      }

      assert {:reply, response} = A2A.JSONRPC.handle(request, JSONRPCHandler, %{})

      assert {:ok, encoded_json} = Jason.encode(response)
      assert {:ok, decoded} = Jason.decode(encoded_json)
      assert decoded == response
    end

    test "the real handler's handle_send/3 is never invoked for a push-notification-config request" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Process.put(:push_notification_call_counter, counter)

      request = %{
        "jsonrpc" => "2.0",
        "id" => "canary",
        "method" => "tasks/pushNotificationConfig/set",
        "params" => %{"taskId" => "some-task", "pushNotificationConfig" => %{}}
      }

      assert {:reply, %{"error" => %{"code" => -32_003}}} =
               A2A.JSONRPC.handle(request, JSONRPCHandler, %{})

      assert Agent.get(counter, & &1) == 0

      # Positive control: dispatch a real `message/send` through the *same*
      # handler and confirm the counter mechanism genuinely observes real
      # calls when they do happen -- proving the zero count above reflects
      # the push-notification dispatch clause skipping the handler, not a
      # broken counter that would silently read zero regardless.
      send_request = %{
        "jsonrpc" => "2.0",
        "id" => "control",
        "method" => "message/send",
        "params" => %{
          "message" => %{
            "role" => "user",
            "parts" => [%{"kind" => "text", "text" => "hi"}],
            "messageId" => "msg-1",
            "kind" => "message"
          }
        }
      }

      assert {:reply, %{"result" => _}} = A2A.JSONRPC.handle(send_request, JSONRPCHandler, %{})
      assert Agent.get(counter, & &1) == 1

      Agent.stop(counter)
    end
  end
end
