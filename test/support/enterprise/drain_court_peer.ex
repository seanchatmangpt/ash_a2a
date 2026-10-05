# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Test.DrainCourtPeer do
  @moduledoc false

  alias AshA2A.Cluster.DrainManager
  alias AshA2A.Cluster.HealthPlug
  alias AshA2A.TaskStore.Ekv

  @all_steps ["s1", "s2", "s3", "s4"]

  # Runs on the PRIMARY: installs a telemetry handler that forwards the
  # cluster handover event cross-node to the test process. The handler
  # closure is created on the peer so it survives code-loading races.
  def start_event_forwarder(node_a, test_pid) do
    :erpc.call(node_a, __MODULE__, :install_event_forwarder, [test_pid])
  end

  def install_event_forwarder(test_pid) do
    # The peer boots as a bare distribution node; :telemetry's handler
    # table GenServer only exists once the app is started.
    {:ok, _} = Application.ensure_all_started(:telemetry)
    handler_id = :"drain_court_forwarder_#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:ash_a2a, :cluster, :handover],
        fn _event, _measurements, meta, _config ->
          send(test_pid, {:drain_court_handover, meta})
        end,
        nil
      )

    handler_id
  end

  # Runs on the PEER: boots the full drain-tree and returns the
  # identities the primary needs to address it.
  def start_tree(%{
        data_dir: data_dir,
        http_port: port,
        drain_timeout_ms: timeout,
        forwarder: _forwarder
      }) do
    # The peer boots as a bare distribution node: start the applications
    # the tree's children need before supervising them.
    {:ok, _} = Application.ensure_all_started(:telemetry)
    {:ok, _} = Application.ensure_all_started(:ekv)
    :persistent_term.put({__MODULE__, :port}, port)

    id = System.unique_integer([:positive])
    store_name = :"store_drain_court_#{id}"
    dm_name = :"dm_drain_court_#{id}"
    sup_name = :"tasksup_drain_court_#{id}"

    # The erpc worker process that runs this function exits as soon as it
    # returns, and a start_link-ed tree dies with its linked parent -- so
    # unlink the tree from this transient process: the tree's lifetime is
    # the node's lifetime, exactly like a real node's supervision tree.
    {:ok, sup} =
      Supervisor.start_link(
        [
          {Task.Supervisor, name: sup_name},
          Ekv.child_spec(name: store_name, data_dir: data_dir),
          {DrainManager,
           name: dm_name,
           task_supervisor: sup_name,
           task_store: {Ekv, store_name},
           drain_timeout_ms: timeout,
           halt_after_drain: true},
          {Bandit,
           plug: {HealthPlug, drain_manager: dm_name, retry_after_s: 30},
           port: port,
           ip: {127, 0, 0, 1}}
        ],
        strategy: :one_for_one
      )

    true = Process.unlink(sup)

    %{
      drain_manager: dm_name,
      task_supervisor: sup_name,
      supervisor: sup,
      store_name: store_name,
      store_tuple: {Ekv, store_name},
      http_port: port
    }
  end

  def run_task(tree, task_id, progress_path, test_pid) do
    {:ok, pid} =
      Task.Supervisor.start_child(
        tree.task_supervisor,
        fn -> task_loop(tree.drain_manager, task_id, progress_path, test_pid, initial_frame()) end
      )

    %{pid: pid, task_id: task_id}
  end

  def task_loop(dm, task_id, progress_path, test_pid, frame) do
    :ok = DrainManager.track(dm, task_id, frame: frame)
    :ok = DrainManager.update_frame(dm, task_id, frame)

    receive do
      {:drain_court, :step, from} ->
        [step | rest] = frame.remaining
        append_step(progress_path, step)
        frame = %{frame | done: frame.done ++ [step], remaining: rest}
        :ok = DrainManager.update_frame(dm, task_id, frame)
        send(from, {:drain_court_stepped, task_id, {:ok, frame}})
        task_loop(dm, task_id, progress_path, test_pid, frame)

      {:drain_court, :finish, from} ->
        send(from, {:drain_court_finished, task_id, node()})
        :ok = DrainManager.release(dm, task_id)
    after
      60_000 ->
        :ok
    end
  end

  # Diagnostic: perform a local loopback HTTP GET /healthz from this peer.
  def healthz_self do
    {:ok, _} = Application.ensure_all_started(:inets)

    case :httpc.request(
           :get,
           {~c"http://127.0.0.1:#{:persistent_term.get({__MODULE__, :port})}/healthz", []},
           [timeout: 2_000, connect_timeout: 2_000],
           []
         ) do
      {:ok, {{_v, status, _p}, _h, body}} -> {status, body}
      {:error, reason} -> {:error, reason}
    end
  end

  def resume_fun(progress_path) do
    fn _task, frame ->
      Enum.each(frame.remaining, &append_step(progress_path, &1))

      {:ok, %{done: frame.done ++ frame.remaining, resumed_on: node()}}
    end
  end

  def append_step(path, step), do: File.write!(path, step <> "\n", [:append])

  def stop_peer(peer_pid) do
    if Process.alive?(peer_pid), do: :peer.stop(peer_pid)
    :ok
  end

  defp initial_frame, do: %{done: [], remaining: @all_steps}
end
