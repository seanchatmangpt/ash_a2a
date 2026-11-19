# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Session.Supervisor do
  @moduledoc """
  Owns the session `Registry` (unique keys) and the `DynamicSupervisor` that starts
  one `AshA2A.Session.Statem` per connection id (FNOX-SJ-SESS-1).
  """

  use Supervisor

  @registry AshA2A.Session.Registry
  @dynamic AshA2A.Session.DynamicSupervisor

  @doc "Registry name."
  def registry, do: @registry

  @doc "DynamicSupervisor name."
  def dynamic_supervisor, do: @dynamic

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, strategy: :one_for_one, name: @dynamic}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc "Starts a session for `conn_id`; `{:error, {:already_started, pid}}` if live."
  @spec start_session(term()) :: DynamicSupervisor.on_start_child()
  def start_session(conn_id),
    do: DynamicSupervisor.start_child(@dynamic, AshA2A.Session.Statem.child_spec(conn_id))

  @doc "Looks up the live session pid for `conn_id`."
  @spec whereis(term()) :: pid() | nil
  def whereis(conn_id) do
    case Registry.lookup(@registry, conn_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end
end
