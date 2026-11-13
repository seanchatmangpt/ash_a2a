defmodule AshA2A.Protocol.Task.OrphanSweep do
  @moduledoc """
  Lease-expiry recovery for orphaned `:working` tasks.

  A task persisted `:working` whose worker died with the node (no drain
  checkpoint) is never finalized. `sweep/2` finds such tasks in a store and
  fails them with a typed `orphaned` status so clients stop polling forever.

  A task is orphaned when it is `:working`, not drain-checkpointed (those are
  adoptable through `AshA2A.Cluster.Handover`), its status timestamp is
  older than `:lease_ms`, and `:live?` (a `task_id -> boolean` supplied by the
  runtime, true when a worker still runs it) says no.

  Runtime hook required (lane 06, `AshA2A.Transport.Runtime`): call
  `OrphanSweep.sweep(task_store, lease_ms: ..., live?: &worker_alive?/1)` at
  runtime/agent start and on a periodic timer, and refresh a working task's
  status timestamp (heartbeat `put`) while its worker runs.
  """

  require Logger

  alias AshA2A.Protocol.Task

  @doc "Fails every orphaned `:working` task in `store`; returns the failed ids."
  @spec sweep({module(), term()}, keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def sweep({store_mod, store_ref}, opts \\ []) do
    lease_ms = Keyword.get(opts, :lease_ms, 60_000)
    live? = Keyword.get(opts, :live?, fn _ -> false end)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    if Code.ensure_loaded?(store_mod) and function_exported?(store_mod, :list_all, 2) do
      case store_mod.list_all(store_ref, status: :working, page_size: 1_000_000) do
        {:ok, %{tasks: tasks}} ->
          {:ok, fail_orphans(tasks, store_mod, store_ref, now, lease_ms, live?)}

        other ->
          {:error, {:list_all_failed, other}}
      end
    else
      :telemetry.execute([:ash_a2a, :task, :orphan_sweep_unsupported], %{count: 1}, %{
        store: store_mod,
        reason: :list_all_missing
      })

      Logger.error(
        "OrphanSweep: task store #{inspect(store_mod)} does not export list_all/2; " <>
          "orphaned :working tasks cannot be recovered"
      )

      {:error, {:unsupported, :list_all}}
    end
  end

  defp fail_orphans(tasks, store_mod, store_ref, now, lease_ms, live?) do
    for task <- tasks, orphaned?(task, now, lease_ms, live?) do
      error = AshA2A.Protocol.Message.new_agent("Error: orphaned (worker lost, lease expired)")
      failed = AshA2A.Protocol.Agent.State.transition(task, :failed, error)
      :ok = store_mod.put(store_ref, failed)

      :telemetry.execute([:ash_a2a, :task, :orphan_failed], %{count: 1}, %{task_id: task.id})
      task.id
    end
  end

  defp orphaned?(%Task{status: %{timestamp: %DateTime{} = ts}} = task, now, lease_ms, live?) do
    not AshA2A.Cluster.Checkpoint.checkpointed?(task) and
      DateTime.diff(now, ts, :millisecond) > lease_ms and not live?.(task.id)
  end

  defp orphaned?(_task, _now, _lease_ms, _live?), do: false
end
