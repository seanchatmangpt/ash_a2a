defmodule AshA2A.Test.FakeDurableServerSupervisor do
  def start_link do
    Agent.start_link(fn -> %{active: %{}, persisted: %{}} end)
  end

  def ensure_started_child(supervisor, {_server_module, spec_opts}, opts) do
    key = Keyword.fetch!(spec_opts, :key)
    initial_state = Keyword.fetch!(spec_opts, :initial_state)
    node = Keyword.get(opts, :node, :node_a)

    Agent.get_and_update(supervisor, fn state ->
      case Map.fetch(state.persisted, key) do
        {:ok, runtime} ->
          {{:ok, runtime}, put_in(state.active[key], runtime)}

        :error ->
          runtime = %{
            key: key,
            node: node,
            generation: 1,
            state: initial_state,
            cordoned?: false
          }

          next =
            state
            |> put_in([:active, key], runtime)
            |> put_in([:persisted, key], runtime)

          {{:ok, runtime}, next}
      end
    end)
  end

  def lookup(supervisor, key) do
    Agent.get(supervisor, &Map.fetch(&1.active, key))
  end

  def rehome_child(supervisor, {_server_module, spec_opts}, opts) do
    key = Keyword.fetch!(spec_opts, :key)
    initial_state = Keyword.fetch!(spec_opts, :initial_state)
    node = Keyword.get(opts, :node, :node_b)

    Agent.get_and_update(supervisor, fn state ->
      previous = Map.get(state.persisted, key)

      runtime = %{
        key: key,
        node: node,
        generation: if(previous, do: previous.generation + 1, else: 1),
        state: if(previous, do: previous.state, else: initial_state),
        cordoned?: false
      }

      next =
        state
        |> put_in([:active, key], runtime)
        |> put_in([:persisted, key], runtime)

      {{:ok, runtime}, next}
    end)
  end

  def terminate_and_cordon_child(supervisor, key, _opts) do
    Agent.get_and_update(supervisor, fn state ->
      case Map.fetch(state.persisted, key) do
        {:ok, runtime} ->
          cordoned = %{runtime | cordoned?: true}

          next =
            state
            |> update_in([:active], &Map.delete(&1, key))
            |> put_in([:persisted, key], cordoned)

          {:ok, next}

        :error ->
          {{:error, :not_found}, state}
      end
    end)
  end

  def uncordon_child(supervisor, key) do
    Agent.get_and_update(supervisor, fn state ->
      case Map.fetch(state.persisted, key) do
        {:ok, runtime} ->
          active = %{runtime | cordoned?: false}

          next =
            state
            |> put_in([:active, key], active)
            |> put_in([:persisted, key], active)

          {:ok, next}

        :error ->
          {{:error, :not_found}, state}
      end
    end)
  end

  def terminate_and_delete_child(supervisor, key, _timeout) do
    Agent.update(supervisor, fn state ->
      state
      |> update_in([:active], &Map.delete(&1, key))
      |> update_in([:persisted], &Map.delete(&1, key))
    end)

    :ok
  end

  def simulate_restart(supervisor, key) do
    Agent.get_and_update(supervisor, fn state ->
      runtime = Map.fetch!(state.persisted, key)
      restarted = %{runtime | generation: runtime.generation + 1}

      next =
        state
        |> put_in([:active, key], restarted)
        |> put_in([:persisted, key], restarted)

      {{:ok, restarted}, next}
    end)
  end

  def simulate_node_loss(supervisor, node) do
    Agent.update(supervisor, fn state ->
      active =
        Map.reject(state.active, fn {_key, runtime} ->
          runtime.node == node
        end)

      %{state | active: active}
    end)

    :ok
  end
end

defmodule AshA2A.DurableServerContinuityTest do
  use ExUnit.Case, async: false

  alias AshA2A.Durability.DurableServer
  alias AshA2A.Identity
  alias AshA2A.Test.FakeDurableServerSupervisor, as: FakeProvider

  setup do
    previous = Application.get_env(:ash_a2a, :durable_server_provider)
    Application.put_env(:ash_a2a, :durable_server_provider, FakeProvider)
    {:ok, supervisor} = FakeProvider.start_link()

    on_exit(fn ->
      if Process.alive?(supervisor), do: Agent.stop(supervisor)

      if is_nil(previous) do
        Application.delete_env(:ash_a2a, :durable_server_provider)
      else
        Application.put_env(:ash_a2a, :durable_server_provider, previous)
      end
    end)

    %{supervisor: supervisor}
  end

  test "restart preserves stable TaskID key and durable state", %{supervisor: supervisor} do
    task_id = Identity.task("restart-fixture")
    task_key = DurableServer.key(task_id)

    assert {:ok, receipt} =
             DurableServer.ensure_task(
               supervisor,
               __MODULE__,
               task_id,
               %{counter: 7},
               node: :node_a
             )

    assert receipt.provider == :durable_server
    assert receipt.operation == :ensure_started_child
    assert receipt.status == :completed
    assert {:ok, before_restart} = DurableServer.lookup(supervisor, task_id)
    assert before_restart.key == task_key
    assert before_restart.generation == 1
    assert before_restart.state == %{counter: 7}

    assert {:ok, restarted} = FakeProvider.simulate_restart(supervisor, task_key)
    assert restarted.generation == 2

    assert {:ok, after_restart} = DurableServer.lookup(supervisor, task_id)
    assert after_restart.key == task_key
    assert after_restart.generation == 2
    assert after_restart.state == %{counter: 7}
  end

  test "node loss is observable and rehome is separately receipted", %{supervisor: supervisor} do
    task_id = Identity.task("node-loss-fixture")
    task_key = DurableServer.key(task_id)

    assert {:ok, _receipt} =
             DurableServer.ensure_task(
               supervisor,
               __MODULE__,
               task_id,
               %{counter: 11},
               node: :node_a
             )

    assert :ok = FakeProvider.simulate_node_loss(supervisor, :node_a)
    assert :error = DurableServer.lookup(supervisor, task_id)

    assert {:ok, rehome_receipt} =
             DurableServer.rehome_task(
               supervisor,
               __MODULE__,
               task_id,
               %{counter: 0},
               node: :node_b
             )

    assert rehome_receipt.provider == :durable_server
    assert rehome_receipt.operation == :rehome_child
    assert rehome_receipt.status == :completed

    assert {:ok, recovered} = DurableServer.lookup(supervisor, task_id)
    assert recovered.key == task_key
    assert recovered.node == :node_b
    assert recovered.generation == 2
    assert recovered.state == %{counter: 11}
  end
end
