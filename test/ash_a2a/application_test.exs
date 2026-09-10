defmodule AshA2A.ApplicationTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Exercises `AshA2A.Application.start/2` for real. Every other test in this
  suite that needs a running `A2A.AgentSupervisor` bypasses this module and
  calls `A2A.AgentSupervisor.start_link/1` directly (see
  `test/ash_a2a_test.exs` and `test/ash_a2a_registry_test.exs`) -- so
  `AshA2A.Application.start/2` itself, and the real `A2A.AgentSupervisor`
  child spec it wires under `AshA2A.Supervisor`, were never actually
  invoked anywhere in the suite. This file closes that gap.

  Because `:ash_a2a` is declared with `mod: {AshA2A.Application, []}` in
  `mix.exs`, `mix test` already starts the real application (and therefore
  already calls `start/2`) before any test runs. Each test here stops the
  already-running `:ash_a2a` application, calls `AshA2A.Application.start/2`
  directly, asserts on the real resulting supervision tree, then restores
  the application to a running state so later test files (which assume a
  running `:ash_a2a` app) are unaffected.
  """

  setup do
    Application.stop(:ash_a2a)

    on_exit(fn ->
      Application.ensure_all_started(:ash_a2a)
    end)

    :ok
  end

  test "start/2 returns a real, running top-level supervisor named AshA2A.Supervisor" do
    assert {:ok, pid} = AshA2A.Application.start(:normal, [])
    assert is_pid(pid)
    assert Process.alive?(pid)
    assert Process.whereis(AshA2A.Supervisor) == pid

    Supervisor.stop(pid)
  end

  test "start/2 actually starts a real A2A.AgentSupervisor child under it" do
    {:ok, pid} = AshA2A.Application.start(:normal, [])

    children = Supervisor.which_children(pid)

    assert [{A2A.AgentSupervisor, child_pid, :supervisor, _modules}] = children
    assert is_pid(child_pid)
    assert Process.alive?(child_pid)

    # The A2A.AgentSupervisor child is a real, independently-running
    # supervisor (not a mock/stub) -- it starts its own real A2A.Registry
    # child underneath, with no agents configured for this test app.
    assert Process.whereis(A2A.Registry) != nil
    assert [{A2A.Registry, registry_pid, _, _}] = Supervisor.which_children(child_pid)
    assert Process.alive?(registry_pid)

    Supervisor.stop(pid)
  end

  test "start/2 reads real agents from Application config and starts them under the real supervisor" do
    previous = Application.get_env(:ash_a2a, :agents, [])
    Application.put_env(:ash_a2a, :agents, [AshA2A.Test.Fixture.EchoAgent])

    on_exit(fn -> Application.put_env(:ash_a2a, :agents, previous) end)

    {:ok, pid} = AshA2A.Application.start(:normal, [])

    [{A2A.AgentSupervisor, agent_sup_pid, :supervisor, _}] = Supervisor.which_children(pid)

    agent_children = Supervisor.which_children(agent_sup_pid)

    assert Enum.any?(agent_children, fn {id, child_pid, _type, _modules} ->
             id == AshA2A.Test.Fixture.EchoAgent and is_pid(child_pid) and
               Process.alive?(child_pid)
           end)

    Supervisor.stop(pid)
  end
end
