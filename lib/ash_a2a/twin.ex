defmodule AshA2A.Twin do
  @moduledoc """
  Communicating Digital Twins subsystem (v26.11.7 spec §3) — sensory
  periphery for the A2A agent surface.

  Supervisor for twin actors: `AshA2A.Twin.Asset`, `AshA2A.Twin.Partner`,
  `AshA2A.Twin.Operator` — each a `gen_statem` under a `DynamicSupervisor`,
  local in-memory state only (no store dependency). Twins communicate by
  exchanging typed events to a listener pid. `AshA2A.Twin.Lease` is an
  independent pure monotonic-lease module available to callers; the twin
  actors themselves do not hold leases. The `AshA2A.Twin.Hazard` monitor
  carries the robust median/MAD statistics.

  Design handoff (from ash_pplan lane T1):
  `/Users/sac/ash_pplan/notes/twin-handoff-ash-a2a.md`.
  """

  use Supervisor

  @doc "Start the twin subsystem supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    Supervisor.init(
      [
        {DynamicSupervisor, name: AshA2A.Twin.TwinSupervisor},
        {Registry, keys: :unique, name: AshA2A.Twin.Registry}
      ],
      strategy: :one_for_one
    )
  end

  @doc "Start a twin of the given module (Asset/Partner/Operator) under the dynamic supervisor."
  @spec start_twin(module(), atom(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_twin(module, name, opts \\ []) do
    DynamicSupervisor.start_child(
      AshA2A.Twin.TwinSupervisor,
      {module, [name: name] ++ opts}
    )
  end

  @doc "Pids of all live twin actors ([] when the twin supervisor is down)."
  @spec twins() :: [pid()]
  def twins do
    try do
      DynamicSupervisor.which_children(AshA2A.Twin.TwinSupervisor)
      |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
    rescue
      # supervisor mid-restart or stopped: no live twins observable
      _ -> []
    catch
      :exit, _ -> []
    end
  end

  @doc "Count of live twin actors (orphan check: zero after supervisor shutdown)."
  @spec count_twins() :: non_neg_integer()
  def count_twins, do: twins() |> length()
end
