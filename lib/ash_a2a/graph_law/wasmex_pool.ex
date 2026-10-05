# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.GraphLaw.WasmexPool do
  @moduledoc """
  N supervised `AshA2A.GraphLaw.WasmexHost` instances over one compiled engine
  (PERF-06).

  A single `WasmexHost` serializes every transaction, so one host caps GraphLaw
  throughput at one core no matter how many schedulers the node has. This
  supervisor starts `:size` hosts (default `System.schedulers_online/0`,
  configurable as `config :ash_a2a, :graphlaw_pool_size`). Member 0 keeps the
  registered name `AshA2A.GraphLaw.WasmexHost`, so every existing caller of the
  default server name keeps working; every member joins a duplicate-key
  `Registry` under `:members`, and `WasmexHost` routes calls to its default
  name to the member with the shortest mailbox (`pick/1`).

  Startup cost is one Cranelift compile plus N instantiations: the compiled
  module is shared through `AshA2A.GraphLaw.EngineLoad.load/3`'s per-node
  cache, while each member keeps its own store (fuel, memory limit, interrupt
  flag) and its own instance.

  Load shedding is per member: a member whose mailbox already holds
  `:graphlaw_max_queue` messages refuses with `:graphlaw_saturated`, so a
  burst is bounded by `size * max_queue` queued calls instead of growing
  without limit.

  GraphLaw derives and validates; nothing here authorizes or actuates.
  """

  use Supervisor

  @registry AshA2A.GraphLaw.Registry

  @doc "The default registry name the pool's members join."
  @spec registry() :: atom()
  def registry, do: @registry

  @doc """
  Starts the pool. Options: `:name` (supervisor name, default this module),
  `:registry` (default `#{inspect(@registry)}`), `:size`, `:host_name` (the
  registered name of member 0, default `AshA2A.GraphLaw.WasmexHost`; `nil`
  leaves it unnamed), and any `AshA2A.GraphLaw.WasmexHost` option (passed to
  every member).
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc "Pool size resolved from `opts[:size]`, config, then scheduler count."
  @spec size(keyword()) :: pos_integer()
  def size(opts \\ []) do
    Keyword.get(opts, :size) ||
      Application.get_env(:ash_a2a, :graphlaw_pool_size) ||
      System.schedulers_online()
  end

  @impl true
  def init(opts) do
    registry = Keyword.get(opts, :registry, @registry)
    n = size(opts)
    host_name = Keyword.get(opts, :host_name, AshA2A.GraphLaw.WasmexHost)
    host_opts = Keyword.drop(opts, [:registry, :size, :host_name])

    members =
      for i <- 0..(n - 1) do
        name = if i == 0, do: host_name, else: nil

        Supervisor.child_spec(
          {AshA2A.GraphLaw.WasmexHost, Keyword.merge(host_opts, name: name, registry: registry)},
          id: {AshA2A.GraphLaw.WasmexHost, i}
        )
      end

    children = [{Registry, keys: :duplicate, name: registry} | members]
    # `:rest_for_one`: the registry is the first child and every member joins it
    # from `init/1`. A registry crash drops all registrations, so the members
    # started after it must restart and re-register; `:one_for_one` would leave
    # live but unroutable members behind (a restarted registry with 0 members).
    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  The live member with the shortest mailbox, or `nil` when no pool is running
  under `registry`.
  """
  @spec pick(atom()) :: pid() | nil
  def pick(registry \\ @registry) do
    registry
    |> members()
    |> Enum.map(fn pid -> {queue_len(pid), pid} end)
    |> Enum.reject(fn {len, _} -> is_nil(len) end)
    |> Enum.min_by(&elem(&1, 0), fn -> {nil, nil} end)
    |> elem(1)
  end

  @doc "Every live member pid."
  @spec members(atom()) :: [pid()]
  def members(registry \\ @registry) do
    if Process.whereis(registry),
      do: registry |> Registry.lookup(:members) |> Enum.map(&elem(&1, 0)),
      else: []
  rescue
    # A registry mid-restart has its name registered before its key table
    # exists: `Registry.lookup/2` raises "unknown registry". No member is
    # routable in that window.
    ArgumentError -> []
  end

  defp queue_len(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, len} -> len
      nil -> nil
    end
  end
end
