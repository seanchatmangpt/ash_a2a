defmodule AshA2A.DurableServerTest do
  use ExUnit.Case, async: true

  alias AshA2A.{Durability.DurableServer, Identity}

  test "A2A task identity is the stable durable runtime key" do
    task_id = Identity.task("task-42")
    assert DurableServer.key(task_id) == "task:task-42"
  end

  test "missing DurableServer provider returns typed unsupported without inventing durability" do
    unless DurableServer.available?() do
      assert {:error, {:unsupported, :durable_server, :lookup, 2}} =
               DurableServer.lookup(:missing_supervisor, Identity.task("task-42"))
    end
  end
end
