# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Session.HibernateTest do
  use ExUnit.Case, async: false

  alias AshA2A.Session.Hibernate

  # Bounded poll on an observable; the deadline is a monotonic instant, no sleeps.
  defp hibernated?(pid, deadline) do
    cond do
      Process.info(pid, :current_function) in [
        {:current_function, {:erlang, :hibernate, 3}},
        {:current_function, {:gen_statem, :loop_hibernate, 3}}
      ] ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        :erlang.yield() && hibernated?(pid, deadline)
    end
  end

  defp await_hibernate(pid), do: hibernated?(pid, System.monotonic_time(:millisecond) + 3_000)

  test "idle session hibernates and wakes with state plus the event's effect" do
    {:ok, pid} = Hibernate.start_link("conn-hib", 20)
    assert {:ok, :projecting} = Hibernate.send_event(pid, :hydrated)
    pre = :sys.get_state(pid)
    assert {:projecting, %{transitions: 1, idle_ms: 20, conn_id: "conn-hib"}} = pre

    assert await_hibernate(pid)

    assert {:ok, :awaiting_step_up} = Hibernate.send_event(pid, :projected)
    {pre_state, pre_data} = pre
    assert pre_state == :projecting

    assert :sys.get_state(pid) ==
             {:awaiting_step_up, %{pre_data | transitions: pre_data.transitions + 1}}
  end

  test "state read after hibernation equals state before it" do
    {:ok, pid} = Hibernate.start_link("conn-hib2", 20)
    assert {:ok, :projecting} = Hibernate.send_event(pid, :hydrated)
    pre = :sys.get_state(pid)
    assert await_hibernate(pid)
    assert :sys.get_state(pid) == pre
  end

  test "invalid event on a hibernated session is typed and leaves state untouched" do
    {:ok, pid} = Hibernate.start_link("conn-hib3", 20)
    pre = :sys.get_state(pid)
    assert await_hibernate(pid)

    assert {:error, {:invalid_event, :hydrating, :projected}} =
             Hibernate.send_event(pid, :projected)

    assert :sys.get_state(pid) == pre
  end
end
