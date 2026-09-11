defmodule AshA2A.Test.AgentSupervisorCase do
  @moduledoc """
  Shared real-supervisor bootstrap for tests that start `A2A.AgentSupervisor`
  (ash_a2a ERRC finding: duplicated start/on_exit boilerplate).

  Collapses the verbatim-duplicated pattern that appeared in both
  `test/ash_a2a_registry_test.exs` and `test/ash_a2a_test.exs`: start a real
  `A2A.AgentSupervisor` with a per-test `name:`/`registry:`, and register a
  real `on_exit` that stops it (tolerating the supervisor already being
  down). No Mock/mox/patch involved -- this wraps the same real
  `A2A.AgentSupervisor.start_link/1` and real `Supervisor.stop/1` call sites
  it replaces.
  """

  @doc """
  Starts a real `A2A.AgentSupervisor` for `agents`, registers a real
  `on_exit` teardown, and returns `{sup, registry_name}`.

  `case_module` should be the calling test module's `__MODULE__`, used (as
  the duplicated code did) to derive unique per-test supervisor/registry
  names so parallel test modules don't collide.

  Options:
    * `:on_exit` - the `ExUnit.Callbacks.on_exit/2` function to use.
      Defaults to `ExUnit.Callbacks.on_exit/1`. Exists so callers running
      outside of an ExUnit test process can still get a real supervisor and
      wire their own teardown.
  """
  def start_supervised_agents!(case_module, agents, opts \\ []) do
    sup_name = :"#{case_module}.Sup"
    registry_name = :"#{case_module}.Registry"

    {:ok, sup} =
      A2A.AgentSupervisor.start_link(
        agents: agents,
        name: sup_name,
        registry: registry_name
      )

    on_exit_fun = Keyword.get(opts, :on_exit, &ExUnit.Callbacks.on_exit/1)

    on_exit_fun.(fn ->
      try do
        Supervisor.stop(sup)
      catch
        :exit, _ -> :ok
      end
    end)

    {sup, registry_name}
  end
end
