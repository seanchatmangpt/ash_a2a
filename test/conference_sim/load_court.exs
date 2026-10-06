# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule ConferenceSim.LoadCourt do
  @moduledoc """
  Conference-sim lane EV9 court: conference-scale concurrency — the
  "3,500 attendees" headline as a bounded, honest load test.

  ## Scale honesty

  CI cannot rehearse 3,500 simultaneous attendees. **100 concurrent
  attendee-agents here ≈ 3,500 at the venue — same code path, same real
  machinery** (real `AshA2A.Protocol.Agent` GenServers, real Ash/ETS tasks,
  real signed badge issuance, real subscriber fan-out), exercised at 1/35th
  scale. The ratio is a rehearsal scaling, not a capacity claim: passing at
  100 says the code path is concurrency-safe, NOT that the venue handles
  3,500 — venue-scale numbers need venue-scale load, which stays
  `UNKNOWN` here.

  ## Degradation honesty

  The scale is a `@load_scale` module attribute read from
  `CONFERENCE_SIM_LOAD_SCALE` (default 100). If a machine cannot run 100,
  the operator lowers the env var and the court **reports what WAS
  achieved** (via the per-court scale banner) and asserts the achieved
  count EQUALS the configured scale — never silently fewer.

  ## Courts

    * **Concurrent registration** — `@load_scale` attendee-agents issue
      badges concurrently through the REAL registration-authority agent
      (`issue_badge` skill → real `CardSigning.sign/3` card). All succeed;
      all issued receipts are for unique attendee ids.
    * **Concurrent session creation** — `@load_scale` concurrent
      `open_session` task creates on the venue agent. All succeed; all task
      ids (and session ids) are unique.
    * **Concurrent stream subscriptions** — `@load_scale` subscribers race
      to subscribe to ONE live session task, then all receive the session's
      `{:a2a_task_event, task_id, task}` fan-out.
    * **Mixed workload** — 50% task creates + 30% stream subscriptions +
      20% push-config registrations (of `@load_scale`), all under
      supervised (`Task.Supervisor`) async tasks — every task completes.

  Timing assertions are FLOORS not ceilings: durations are measured,
  reported, and only asserted to be non-negative / events to have arrived —
  no upper bounds, so a slow CI box never flakes.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Protocol.PushNotificationConfig

  @tag :load_scale
  @load_scale (case System.get_env("CONFERENCE_SIM_LOAD_SCALE") do
                 nil -> 100
                 "" -> 100
                 v -> String.to_integer(v)
               end)

  setup do
    {:ok, sim} = ConferenceSim.build(attendees: @load_scale)

    on_exit(fn ->
      ConferenceSim.teardown(sim)
    end)

    {:ok, sup} = Task.Supervisor.start_link(name: ConferenceSimLoadTaskSup)
    on_exit(fn -> if Process.alive?(sup), do: Supervisor.stop(sup) end)

    IO.puts("""
    \n[load_court] configured scale: #{@load_scale} concurrent attendee-agents \
    (100 here ≈ 3,500 at the venue, same code path)
    """)

    %{sim: sim}
  end

  # -- helpers -------------------------------------------------------------

  defp data_message(data, skill) when is_atom(skill) do
    msg = AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(data)])
    %{msg | metadata: %{skill: skill}}
  end

  defp artifact_data(task) do
    case task.artifacts do
      [%AshA2A.Protocol.Artifact{parts: [%AshA2A.Protocol.Part.Data{data: data}]}] -> data
      _ -> nil
    end
  end

  defp duration_ms({:mono, start}), do: System.monotonic_time(:millisecond) - start
  defp now(), do: {:mono, System.monotonic_time(:millisecond)}

  defp banner(court, n, elapsed) do
    IO.puts("[load_court] #{court}: #{n} concurrent ops completed in #{elapsed}ms (floor-asserted)")
  end

  # -- court 1: concurrent registration (badge issue) ------------------------

  @tag :conference_sim
  @tag :load_scale
  test "#{@load_scale} concurrent badge registrations all succeed with unique attendee ids", %{
    sim: sim
  } do
    attendees = sim.attendees
    assert length(attendees) == @load_scale

    t0 = now()

    results =
      attendees
      |> Enum.map(fn attendee ->
        Task.Supervisor.async(ConferenceSimLoadTaskSup, fn ->
          {:ok, task} =
            ConferenceSim.BadgeAuthorityAgent.call(
              ConferenceSim.BadgeAuthorityAgent,
              data_message(%{attendee_id: attendee.id, tier: attendee.tier}, :issue_badge)
            )

          {:ok, attendee.id, artifact_data(task)}
        end)
      end)
      |> Task.await_many(60_000)

    elapsed = duration_ms(t0)
    assert elapsed >= 0, "timing assertions are floors"

    assert length(results) == @load_scale

    # All succeeded, all receipts are signed-and-stamped, all ids unique.
    receipts = Enum.map(results, fn {:ok, id, receipt} -> {id, receipt} end)
    assert length(receipts) == @load_scale

    assert Enum.all?(receipts, fn {_id, receipt} ->
             receipt[:signed] == true and receipt[:badge_kid] == ConferenceSim.badge_kid()
           end)

    ids = Enum.map(receipts, fn {id, _} -> id end)
    assert length(Enum.uniq(ids)) == @load_scale, "duplicate registration ids"
    assert Enum.sort(ids) == Enum.sort(Enum.map(attendees, & &1.id))

    banner("registration", @load_scale, elapsed)
  end

  # -- court 2: concurrent session creation on the venue ----------------------

  @tag :conference_sim
  @tag :load_scale
  test "#{@load_scale} concurrent session creates all succeed with unique task ids", %{
    sim: sim
  } do
    t0 = now()

    results =
      Enum.map(1..@load_scale, fn i ->
        Task.Supervisor.async(ConferenceSimLoadTaskSup, fn ->
          track = "track-#{rem(i, 11) + 1}"

          {:ok, session} =
            ConferenceSim.open_session(sim, track, "Load session #{i}")

          {:ok, session}
        end)
      end)
      |> Task.await_many(60_000)

    elapsed = duration_ms(t0)
    assert elapsed >= 0

    assert length(results) == @load_scale

    sessions = Enum.map(results, fn {:ok, s} -> s end)
    task_ids = Enum.map(sessions, & &1.task_id)
    session_ids = Enum.map(sessions, & &1.id)

    assert Enum.all?(sessions, &(&1.track && &1.title))
    assert length(Enum.uniq(task_ids)) == @load_scale, "duplicate venue task ids"
    assert length(Enum.uniq(session_ids)) == @load_scale, "duplicate session ids"

    banner("session-create", @load_scale, elapsed)
  end

  # -- court 3: concurrent stream subscriptions, all receive the event --------

  @tag :conference_sim
  @tag :load_scale
  test "#{@load_scale} concurrent stream subscriptions all connect and all receive the session event",
       %{sim: sim} do
    {:ok, session} = ConferenceSim.open_session(sim, "keynote", "Keynote under load")

    parent = self()

    t0 = now()

    subscribers =
      Enum.map(1..@load_scale, fn i ->
        Task.Supervisor.async(ConferenceSimLoadTaskSup, fn ->
          # Each subscriber connects concurrently...
          {:ok, _snapshot} =
            GenServer.call(ConferenceSim.VenueAgent, {:subscribe, session.task_id}, 30_000)

          send(parent, {:subscribed, i, self()})

          # ...waits for the barrier so the fan-out races ALL subscribers at
          # once, then receives the real {:a2a_task_event, ...} fan-out.
          assert_receive {:go, ^session}, 30_000

          assert_receive {:a2a_task_event, task_id, task}, 30_000
          assert task_id == session.task_id
          assert task.id == session.task_id

          {:ok, i}
        end)
      end)

    # Barrier: every subscriber is connected before the session changes.
    pids =
      for _ <- 1..@load_scale do
        assert_receive({:subscribed, _, pid}, 30_000)
        pid
      end

    for pid <- pids, do: send(pid, {:go, session})

    assert {:ok, _task} = ConferenceSim.session_update(sim, session, "room change: Hall B")

    results = Task.await_many(subscribers, 60_000)
    elapsed = duration_ms(t0)

    assert elapsed >= 0

    assert results == Enum.map(1..@load_scale, &{:ok, &1}),
           "not every subscriber connected and received the event"

    banner("stream-subscribe", @load_scale, elapsed)
  end

  # -- court 4: mixed workload under supervised async --------------------------

  @tag :conference_sim
  @tag :load_scale
  test "mixed workload: #{@load_scale && div(@load_scale, 2)} tasks + #{div(@load_scale, 10) * 3} streams + #{div(@load_scale, 5)} push configs all complete",
       %{sim: sim} do
    n_tasks = div(@load_scale, 2)
    n_streams = div(@load_scale, 10) * 3
    n_push = div(@load_scale, 5)
    total = n_tasks + n_streams + n_push
    assert total == @load_scale

    parent = self()

    {:ok, session} = ConferenceSim.open_session(sim, "mixed", "Mixed-workload keynote")

    t0 = now()

    jobs =
      Enum.concat([
        for i <- 1..n_tasks do
          Task.Supervisor.async(ConferenceSimLoadTaskSup, fn ->
            {:ok, _session} = ConferenceSim.open_session(sim, "mixed-#{rem(i, 11) + 1}", "mixed task #{i}")
            {:task, i}
          end)
        end,
        for i <- 1..n_streams do
          Task.Supervisor.async(ConferenceSimLoadTaskSup, fn ->
            {:ok, _snapshot} =
              GenServer.call(ConferenceSim.VenueAgent, {:subscribe, session.task_id}, 30_000)

            send(parent, {:subscribed, {:stream, i}, self()})

            assert_receive {:go, ^session}, 30_000
            assert_receive {:a2a_task_event, task_id, _}, 30_000
            assert task_id == session.task_id
            {:stream, i}
          end)
        end,
        for i <- 1..n_push do
          Task.Supervisor.async(ConferenceSimLoadTaskSup, fn ->
            {:ok, session} = ConferenceSim.open_session(sim, "mixed", "push-config session #{i}")

            config = %PushNotificationConfig{
              id: "load-push-#{i}",
              task_id: session.task_id,
              url: "https://venue.agntcon.example/hooks/load-#{i}",
              token: "load-token-#{i}"
            }

            {:ok, _stored} =
              GenServer.call(ConferenceSim.VenueAgent, {:set_push_config, config}, 30_000)

            {:push, i}
          end)
        end
      ])

    # Barrier for the stream jobs, then the shared fan-out event.
    stream_pids =
      for _ <- 1..n_streams do
        assert_receive({:subscribed, {:stream, _}, pid}, 30_000)
        pid
      end

    for pid <- stream_pids, do: send(pid, {:go, session})

    assert {:ok, _} = ConferenceSim.session_update(sim, session, "mixed-workload room change")

    results = Task.await_many(jobs, 120_000)
    elapsed = duration_ms(t0)

    assert elapsed >= 0

    # ALL jobs completed — never silently fewer.
    expected =
      Enum.map(1..n_tasks, &{:task, &1}) ++
        Enum.map(1..n_streams, &{:stream, &1}) ++
        Enum.map(1..n_push, &{:push, &1})

    assert Enum.sort(results) == Enum.sort(expected),
           "mixed workload did not fully complete: got #{length(results)} of #{total}"

    banner("mixed", total, elapsed)
  end
end
