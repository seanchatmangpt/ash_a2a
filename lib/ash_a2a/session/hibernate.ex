# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT
# UNSUPPORTED(generator-capability): hand-written; no pack emits a hibernation policy.

defmodule AshA2A.Session.Hibernate do
  @moduledoc """
  Idle hibernation policy for sessions (FNOX-SJ-SESS-4).

  A `:gen_statem` that reuses `AshA2A.Session.Statem` transitions and adds one
  rule: after `idle_ms` with no event, the process hibernates (a generic
  `{:timeout, :idle}` fires the `:hibernate` action). The next event wakes it
  with state and data intact. The timer is re-armed by every event.

  `:sys.get_state/1` returns `{state, data}`; `data` carries `:idle_ms` in
  addition to the `Statem` keys.
  """

  @behaviour :gen_statem

  alias AshA2A.Session.Statem

  @doc "Starts an unregistered hibernating session. `idle_ms` is the idle interval."
  @spec start_link(Statem.conn_id(), pos_integer()) :: :gen_statem.start_ret()
  def start_link(conn_id, idle_ms) when is_integer(idle_ms) and idle_ms > 0,
    do: :gen_statem.start_link(__MODULE__, {conn_id, idle_ms}, [])

  @doc "Sends an event synchronously; same replies as `AshA2A.Session.Statem.send_event/2`."
  @spec send_event(pid(), Statem.event()) :: {:ok, Statem.state()} | {:error, term()}
  defdelegate send_event(pid, event), to: Statem

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init({conn_id, idle_ms}) do
    {:ok, state, data} = Statem.init(conn_id)
    {:ok, state, Map.put(data, :idle_ms, idle_ms), [idle_timer(idle_ms)]}
  end

  @impl true
  def handle_event({:timeout, :idle}, :idle, _state, _data), do: {:keep_state_and_data, [:hibernate]}

  def handle_event(type, content, state, %{idle_ms: idle_ms} = data) do
    case Statem.handle_event(type, content, state, data) do
      {:next_state, next, new_data, actions} ->
        {:next_state, next, new_data, actions ++ [idle_timer(idle_ms)]}

      {:keep_state_and_data, actions} ->
        {:keep_state_and_data, actions ++ [idle_timer(idle_ms)]}

      :keep_state_and_data ->
        {:keep_state_and_data, [idle_timer(idle_ms)]}
    end
  end

  defp idle_timer(idle_ms), do: {{:timeout, :idle}, idle_ms, :idle}
end
