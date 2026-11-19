# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Session.Statem do
  @moduledoc """
  Per-connection session `:gen_statem` (FNOX-SJ-SESS-1).

  One process per connection id, registered in `AshA2A.Session.Supervisor.registry/0`
  and started under its `DynamicSupervisor`. Unlike `AshA2A.Twin.Server`, which is
  one shared actor, a crash here is isolated to a single connection.

  States and the only valid transitions:

      :hydrating        --:hydrated-->      :projecting
      :projecting       --:projected-->     :awaiting_step_up
      :awaiting_step_up --:step_up_done-->  :projecting

  Any other event is answered `{:error, {:invalid_event, state, event}}` and leaves
  the state untouched. `:sys.get_state/1` returns `{state, data}`.
  """

  @behaviour :gen_statem

  @type state :: :hydrating | :projecting | :awaiting_step_up
  @type event :: :hydrated | :projected | :step_up_done
  @type conn_id :: term()

  @transitions %{
    {:hydrating, :hydrated} => :projecting,
    {:projecting, :projected} => :awaiting_step_up,
    {:awaiting_step_up, :step_up_done} => :projecting
  }

  @doc "Child spec; sessions are `:temporary` (a dead connection is not resurrected)."
  def child_spec(conn_id) do
    %{
      id: {__MODULE__, conn_id},
      start: {__MODULE__, :start_link, [conn_id]},
      restart: :temporary,
      type: :worker
    }
  end

  @doc "Starts a session registered under `conn_id` in the session registry."
  @spec start_link(conn_id()) :: :gen_statem.start_ret()
  def start_link(conn_id) do
    :gen_statem.start_link(via(conn_id), __MODULE__, conn_id, [])
  end

  @doc "Registry `:via` name for a connection id."
  @spec via(conn_id()) :: {:via, Registry, {atom(), conn_id()}}
  def via(conn_id), do: {:via, Registry, {AshA2A.Session.Supervisor.registry(), conn_id}}

  @doc """
  Sends an event synchronously. Returns `{:ok, new_state}` or
  `{:error, {:invalid_event, state, event}}`.
  """
  @spec send_event(pid() | conn_id(), event()) ::
          {:ok, state()} | {:error, {:invalid_event, state(), term()}}
  def send_event(pid, event) when is_pid(pid), do: :gen_statem.call(pid, {:event, event})
  def send_event(conn_id, event), do: :gen_statem.call(via(conn_id), {:event, event})

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init(conn_id), do: {:ok, :hydrating, %{conn_id: conn_id, transitions: 0}}

  @impl true
  def handle_event({:call, from}, {:event, event}, state, data) do
    case Map.fetch(@transitions, {state, event}) do
      {:ok, next} ->
        {:next_state, next, %{data | transitions: data.transitions + 1},
         [{:reply, from, {:ok, next}}]}

      :error ->
        {:keep_state_and_data, [{:reply, from, {:error, {:invalid_event, state, event}}}]}
    end
  end

  def handle_event({:call, from}, _other, state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, {:invalid_event, state, :unknown}}}]}
  end

  def handle_event(_type, _content, _state, _data), do: :keep_state_and_data
end
