defmodule AshA2A.FlamePlacementTest do
  use ExUnit.Case, async: true

  alias AshA2A.{Command, Execution.FLAME}
  alias AshA2A.Test.Fixture.Echo

  test "missing FLAME provider fails closed without bypassing CommandBus" do
    unless FLAME.available?() do
      command =
        Command.new("AshA2A.Test.Fixture.Echo.read",
          command_id: "flame-read-1",
          agent_id: "agent-1",
          principal_id: "anonymous"
        )

      message = A2A.Message.new_user([A2A.Part.Data.new(%{})])

      assert {:error, {:unsupported, :flame}} =
               FLAME.run(:ash_a2a_pool, command, message, Echo)
    end
  end
end
