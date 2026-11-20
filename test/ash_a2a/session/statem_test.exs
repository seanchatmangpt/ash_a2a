# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Session.StatemTest do
  use ExUnit.Case, async: false

  alias AshA2A.Session.Statem
  alias AshA2A.Session.Supervisor, as: Sess

  setup do
    # The application tree starts the supervisor; start it here only if absent.
    if Process.whereis(Sess) == nil, do: start_supervised!(Sess)
    :ok
  end

  defp uid, do: "conn-#{System.unique_integer([:positive])}"

  test "session walks hydrating -> projecting -> awaiting_step_up in order" do
    {:ok, pid} = Sess.start_session(uid())

    assert {:hydrating, _} = :sys.get_state(pid)
    assert {:ok, :projecting} = Statem.send_event(pid, :hydrated)
    assert {:projecting, _} = :sys.get_state(pid)
    assert {:ok, :awaiting_step_up} = Statem.send_event(pid, :projected)
    assert {:awaiting_step_up, _} = :sys.get_state(pid)
  end

  test "sessions are isolated: killing one leaves the other untouched" do
    {id1, id2} = {uid(), uid()}
    {:ok, pid1} = Sess.start_session(id1)
    {:ok, pid2} = Sess.start_session(id2)
    {:ok, :projecting} = Statem.send_event(pid2, :hydrated)

    assert [{^pid1, _}] = Registry.lookup(Sess.registry(), id1)
    assert [{^pid2, _}] = Registry.lookup(Sess.registry(), id2)
    refute pid1 == pid2

    before = :sys.get_state(pid2)
    ref = Process.monitor(pid1)
    Process.exit(pid1, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid1, _}, 1_000

    assert Process.alive?(pid2)
    assert :sys.get_state(pid2) == before
  end

  test "invalid event is refused and leaves state unchanged; module is gen_statem" do
    {:ok, pid} = Sess.start_session(uid())
    before = :sys.get_state(pid)

    assert {:error, {:invalid_event, :hydrating, :step_up_done}} =
             Statem.send_event(pid, :step_up_done)

    assert :sys.get_state(pid) == before
    assert {:status, ^pid, {:module, :gen_statem}, _} = :sys.get_status(pid)
  end

  test "duplicate connection id is refused as already_started" do
    id = uid()
    {:ok, pid} = Sess.start_session(id)
    assert {:error, {:already_started, ^pid}} = Sess.start_session(id)
    assert Sess.whereis(id) == pid
  end
end
