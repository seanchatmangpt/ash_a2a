# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule ConferenceSim.FixtureTest do
  @moduledoc """
  Court for the conference-sim shared fixture (lane EV1): a real
  AGNTCon+MCPCon conference spun up over REAL AshA2A machinery — real agent
  GenServers, real signed badge cards, real session tasks with real
  push-config deliveries and subscriber events, and a teardown that verifies
  processes are dead and no ports leaked. Chicago-style: state assertions on
  real processes and real cards, no mocks.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Protocol.CardSigning

  setup do
    {:ok, sim} = ConferenceSim.build(attendees: 10)

    on_exit(fn ->
      ConferenceSim.teardown(sim)
    end)

    {:ok, sim: sim}
  end

  @tag :conference_sim
  test "build/1 spins up 10 real attendees and 3 real exhibitor agents, all alive", %{
    sim: sim
  } do
    assert length(sim.attendees) == 10
    assert Enum.all?(sim.attendees, fn a -> is_pid(a.pid) and Process.alive?(a.pid) end)
    assert length(sim.exhibitors) == 3
    assert Enum.all?(sim.exhibitors, fn e -> is_pid(e.pid) and Process.alive?(e.pid) end)

    assert Process.alive?(GenServer.whereis(ConferenceSim.BadgeAuthorityAgent))
    assert Process.alive?(GenServer.whereis(ConferenceSim.VenueAgent))

    # Tier rotation across the 10 attendees covers all four tiers.
    tiers = sim.attendees |> Enum.map(& &1.tier) |> Enum.uniq() |> Enum.sort()
    assert tiers == Enum.sort(ConferenceSim.tiers())
  end

  @tag :conference_sim
  test "every attendee badge is a real signed agent card that verifies against the venue key",
       %{sim: sim} do
    Enum.each(sim.attendees, fn attendee ->
      badge = attendee.badge
      assert %AshA2A.Protocol.AgentCard{} = badge
      assert badge.name == "badge:#{attendee.id}"
      assert [%{"protected" => _, "header" => _, "signature" => _}] = badge.signatures

      assert CardSigning.verify(badge, sim.venue_key) == :ok

      assert {:error, {:bad_signature, _}} =
               CardSigning.verify(badge, :crypto.strong_rand_bytes(32))
    end)
  end

  @tag :conference_sim
  test "tiers map to auth scopes; badge descriptions carry the tier's scopes", %{sim: sim} do
    assert ConferenceSim.tier_scopes(:general) == ["session:scan"]
    assert ConferenceSim.tier_scopes(:workshop) == ["session:scan", "workshop:join"]

    assert ConferenceSim.tier_scopes(:vip) == [
             "session:scan",
             "workshop:join",
             "vip:lounge",
             "seat:front_row"
           ]

    assert ConferenceSim.tier_scopes(:press) == ["session:scan", "press:interview"]
    assert {:error, {:unknown_tier, :speaker}} = ConferenceSim.tier_scopes(:speaker)

    vip = Enum.find(sim.attendees, &(&1.tier == :vip))
    assert vip.badge.description =~ "vip:lounge"
  end

  @tag :conference_sim
  test "all agent cards are fetchable from the real running agents", %{sim: sim} do
    authority_card = ConferenceSim.fetch_card(ConferenceSim.BadgeAuthorityAgent)
    assert authority_card.name == "agntcon_registration_authority"

    assert Enum.any?(
             authority_card.skills,
             &(&1.name == "issue_badge" and String.contains?(&1.id, "issue_badge"))
           )

    venue_card = ConferenceSim.fetch_card(ConferenceSim.VenueAgent)
    assert venue_card.name == "agntcon_venue"

    Enum.each(sim.exhibitors, fn exhibitor ->
      card = ConferenceSim.fetch_card(exhibitor.module)
      assert card.name == exhibitor.name
      assert card.name =~ ~r/^booth_/
    end)
  end

  @tag :conference_sim
  test "badge scanning is scope-gated and recorded on the real attendee process", %{sim: sim} do
    general = Enum.find(sim.attendees, &(&1.tier == :general))
    vip = Enum.find(sim.attendees, &(&1.tier == :vip))

    assert ConferenceSim.scan(sim, general, "talk-042") == :ok
    assert ConferenceSim.scan(sim, general, "booth_acme_ai") == :ok
    assert {:error, :scope_denied} = ConferenceSim.scan(sim, general, "workshop:rust-interop")

    assert ConferenceSim.scan(sim, vip, "workshop:rust-interop") == :ok
    assert "workshop:rust-interop" in ConferenceSim.scans(vip)
    assert "talk-042" in ConferenceSim.scans(general)
    assert "booth_acme_ai" in ConferenceSim.scans(general)
  end

  @tag :conference_sim
  test "sessions are real tasks; changes fan out as push-config deliveries and subscriber events",
       %{sim: sim} do
    {:ok, session} = ConferenceSim.open_session(sim, "a2a_deep_dive", "Agent Cards in Production")
    assert is_binary(session.task_id)
    assert session.track == "a2a_deep_dive"

    # The session task is genuinely non-terminal on the venue's task store.
    {:ok, fetched} = ConferenceSim.VenueAgent.get_task(ConferenceSim.VenueAgent, session.task_id)
    assert fetched.status.state == :input_required

    :ok = ConferenceSim.watch_session(sim, session)

    {:ok, task} = ConferenceSim.session_update(sim, session, "Hall B")
    assert task.id == session.task_id
    assert task.status.state == :completed

    # Real push-config delivery recorded by the real PushRecorder sender.
    # Delivery is spawned off-process (PushNotification.spawn_delivery), so
    # poll briefly for the recorded insert instead of asserting synchronously.
    deliveries =
      Enum.reduce_while(1..50, [], fn _, _ ->
        case ConferenceSim.push_deliveries(sim, session.task_id) do
          [] -> Process.sleep(100) && {:cont, []}
          deliveries -> {:halt, deliveries}
        end
      end)

    assert [_ | _] = deliveries

    assert Enum.any?(
             deliveries,
             fn {task_id, config_id, _url, _payload} ->
               task_id == session.task_id and config_id == "watch-#{session.task_id}"
             end
           )

    # Real stream event pushed to the real subscriber registration.
    assert_receive({:a2a_task_event, task_id, event_task}, 5_000)
    assert task_id == session.task_id
    assert event_task.id == session.task_id
    assert event_task.status.state == :completed
  end

  @tag :conference_sim
  test "booth calls dispatch the MCP-flavored call_tool skill on the real exhibitor agent", %{
    sim: sim
  } do
    acme = Enum.fetch!(sim.exhibitors, 0)

    {:ok, result} = ConferenceSim.booth_call(acme, "list_capabilities")

    assert result["jsonrpc"] == "2.0"
    assert result["tool"] == "list_capabilities"
    assert [%{"type" => "text", "text" => text}] = result["result"]["content"]
    assert text =~ "list_capabilities"
  end

  @tag :conference_sim
  test "teardown/1 kills everything and verifies no port leaks", %{sim: sim} do
    ports_before = sim.ports_before
    assert :ok = ConferenceSim.teardown(sim)

    Enum.each(sim.attendees, fn a -> refute Process.alive?(a.pid) end)
    Enum.each(sim.exhibitors, fn e -> refute Process.alive?(e.pid) end)
    case GenServer.whereis(ConferenceSim.VenueAgent) do
      nil -> :ok
      pid -> refute Process.alive?(pid)
    end

    assert Port.list() -- ports_before == []
  end

  @tag :conference_sim
  test "registration authority agent issues a badge receipt through the real dispatch path", %{
    sim: sim
  } do
    message =
      AshA2A.Protocol.Message.new_user([
        AshA2A.Protocol.Part.Data.new(%{attendee_id: "walkup-1", tier: :press})
      ])

    {:ok, task} =
      ConferenceSim.BadgeAuthorityAgent.call(ConferenceSim.BadgeAuthorityAgent, message)

    assert task.status.state == :completed

    assert [%AshA2A.Protocol.Artifact{parts: [%AshA2A.Protocol.Part.Data{data: data}]}] =
             task.artifacts

    assert data[:attendee_id] == "walkup-1"
    assert data[:tier] == :press
    assert data[:badge_kid] == ConferenceSim.badge_kid()
    assert data[:signed] == true
  end
end
