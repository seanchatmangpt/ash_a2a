defmodule AshA2A.Test.DurableServerFixture do
  @moduledoc """
  A real `DurableServer` implementation, backed by the real `durable_server`
  hex package, used by `AshA2A.RuntimeProvidersIntegrationTest` to exercise
  `AshA2A.Durability.DurableServer` against an actual durable GenServer
  rather than a substitute provider module.
  """
  use DurableServer, vsn: 1

  @impl true
  def dump_state(state), do: %{count: Map.get(state, :count, 0)}

  @impl true
  def load_state(_old_vsn, %{"count" => count}), do: %{count: count}
  def load_state(_old_vsn, _), do: %{count: 0}

  @impl true
  def init(state), do: {:ok, Map.put_new(state, :count, 0)}

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state.count, state}

  @impl true
  def handle_call(:increment, _from, state) do
    new_state = %{state | count: state.count + 1}
    {:reply, new_state.count, new_state}
  end
end
