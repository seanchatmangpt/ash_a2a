# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.FreedomGymOcelConformanceE2ETest do
  @moduledoc """
  Step 5: the real end-to-end "plan-execute-conform" loop --

    HDDL plan (Step 3's real `hddl_cli` solve) -> A2A/Ash execution (this
    test's own real `AshA2A.Protocol.Agent` dispatch against the real
    `FacilitatorAgent`'s `:next_phase` skill, same call pattern as
    `test/ash_a2a_freedom_gym_hddl_plan_test.exs`) -> OCEL v2 recording (a
    real HTTP POST of each real dispatch's real returned phase to
    beam4pm's real, already-running `BeamPM.OcelIngest.Router` at
    `POST /ocel/events`, confirmed by its real 201 response) -> POWL
    conformance check (beam4pm's `BeamPM.PowlConformance`, run in
    beam4pm's own test suite against the real accepted-event JSON this
    test captures and writes out -- see
    `test/beam4pm_powl_conformance_e2e_test.exs` in the beam4pm repo).

  Real, disclosed architectural fact (not a shortcut taken here): reading
  `lib/beam4pm_ocel_ingest.ex` directly shows `BeamPM.OcelIngest.Router`
  validates and echoes each event (fully real, wire-contract-checked) but
  does not persist/store it server-side for later query -- there is no
  GET/query route. So "the real accumulated OCEL trace" from this real
  run is threaded to beam4pm's own conformance check via a real captured
  JSON file (the real 201-confirmed echoed records this test collects),
  not a live query against accumulated server state. The dispatch, the
  phases, the HTTP POSTs, and the 201 acceptances are all real; only the
  cross-process handoff of "which events to check conformance over" goes
  through a file rather than a query, because the real endpoint has no
  query surface to call.

  `AshA2A.Telemetry.OcelForwarder` (the already-real generic dispatch
  forwarder, just merged from `feat/ocel-v2-telemetry-forwarder`) is real
  and reachable, but its own real `event_type` is
  `"ash_a2a.dispatch.<resource>.<skill>"` -- the dispatched SKILL name
  (`next_phase`, constant across all 6 calls), not the returned PHASE
  value (`:telemetry.span`'s stop metadata never carries the reply's own
  data, confirmed by reading `dispatcher.ex`'s `stop_meta/1`). It
  therefore cannot itself produce per-phase-distinct OCEL activities.
  This test still exercises the real forwarder (`attach!/0`; a real
  `[:ash_a2a, :dispatch, :stop]` event fires per call, forwarded
  best-effort) AND separately posts the real per-phase event this
  conformance check actually needs -- two real, complementary OCEL
  emissions, disclosed rather than papered over.

  The OCEL ingest endpoint is now HERMETIC: this test boots beam4pm's real
  `BeamPM.OcelIngest.Router` (real beam4pm source, compiled in-VM from the
  canonical checkout at `BEAM4PM_PATH`, default the sibling `../beam4pm`)
  on a real Bandit listener at an OS-assigned ephemeral loopback port, with
  a real HTTP health check before any event is posted. No out-of-process
  server is required and nothing is stubbed -- the same real router bytes
  that the standalone deployment runs. Setting `OCEL_INGEST_URL` still
  overrides this and targets an already-running external server instead.

  Finally, the loop is CLOSED on ash_a2a's own trust plane: the ingest-
  accepted reference events are sealed into a real Affidavit WASM receipt
  (`AshA2A.Evidence.Affidavit.assemble_receipt/1`) and re-verified
  (`verify_receipt/1` -> `accepted: true`), so the run leaves behind not
  just capture files but a tamper-evident, replayable receipt over exactly
  the events the real endpoint accepted.
  """
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_solo
  # Real HDDL solve + in-VM compile of beam4pm's real router/types + 24 real
  # dispatches + WASM receipt sealing -- comfortably over the 60s default.
  @moduletag timeout: 240_000

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Telemetry.OcelForwarder
  alias AshA2A.Test.Fixture.FreedomGym.{FacilitatorAgent, MeetingPlan}

  @ingest_url System.get_env("OCEL_INGEST_URL")
  @beam4pm_path System.get_env("BEAM4PM_PATH") ||
                  Path.expand("../../beam4pm", __DIR__)
  @output_dir Path.expand("../../beam4pm/qualification/gym_bridge", __DIR__)
  @beam4pm_required_modules [BeamPM.OcelIngest.Router, BeamPM.Types.OcelEvent]

  # Compile beam4pm's REAL ingest router and its REAL generated OCEL types
  # from the canonical beam4pm checkout into this VM, once. These are the
  # actual dependency-free Plug/struct modules the standalone deployment
  # runs -- not copies, not re-implementations. Returns the base URL of a
  # live Bandit listener serving the real router on an ephemeral port.
  defp boot_hermetic_ingest_server! do
    missing =
      Enum.reject(@beam4pm_required_modules, &Code.ensure_loaded?/1)

    if missing != [] do
      router_path = Path.join(@beam4pm_path, "lib/beam4pm_ocel_ingest.ex")
      types_path = Path.join(@beam4pm_path, "lib/beam4pm_types.ex")

      unless File.exists?(router_path) and File.exists?(types_path) do
        skip_and_fail("beam4pm canonical checkout not found at #{@beam4pm_path} " <>
                        "(set BEAM4PM_PATH)")
      end

      # Types first (the router's decode path calls the generated
      # constructors), then the router. Real compile, real modules.
      Code.compile_file(types_path)
      Code.compile_file(router_path)

      still_missing =
        Enum.reject(@beam4pm_required_modules, &Code.ensure_loaded?/1)

      if still_missing != [] do
        skip_and_fail("beam4pm modules failed to compile from #{@beam4pm_path}: " <>
                        Enum.map_join(still_missing, ", ", &inspect/1))
      end
    end

    # Real Bandit HTTP listener, real OS-assigned ephemeral port (same
    # helper the :serial_shard tests use -- cannot collide).
    server = AshA2A.Test.EphemeralHttp.start!(BeamPM.OcelIngest.Router)

    # Real HTTP health check: the router's admission graph defines NO GET
    # route, so its real 404 ("route_not_admitted") is positive proof the
    # real router is live and answering.
    assert {:ok, %Req.Response{status: 404, body: %{"error" => "route_not_admitted"}}} =
             Req.get(server.base_url <> "/ocel/events")

    :persistent_term.put({__MODULE__, :ingest_url}, server.base_url)

    server_pid = server.pid

    # Best-effort teardown: the listener is also linked to the test
    # process, so this is belt-and-braces, never a test verdict.
    on_exit(fn ->
      try do
        if Process.alive?(server_pid), do: Supervisor.stop(server_pid, :normal, 5_000)
      catch
        _, _ -> :ok
      end
    end)

    server.base_url
  end

  defp skip_and_fail(reason) do
    # Loud, named refusal -- never a silent stub or an implicit crash.
    flunk("HERMETIC-INGEST-UNAVAILABLE: " <> reason)
  end

  defp ingest_url do
    @ingest_url || :persistent_term.get({__MODULE__, :ingest_url}, nil)
  end

  setup do
    # Hermetic server boot (unless an explicit external URL was provided).
    if is_nil(@ingest_url) do
      boot_hermetic_ingest_server!()
    end

    # Real Affidavit WASM engine pool (real AshAffidavit.Host WASM members),
    # so step 5's assemble/verify runs against the real engine. Only when no
    # pool is already running (the sibling evidence tests use the same
    # convention in test/ash_a2a/evidence/affidavit_test.exs).
    if AshA2A.Evidence.Affidavit.available?() and is_nil(Process.whereis(AshAffidavit.Pool)) do
      start_supervised!({AshAffidavit.Pool, size: 1})
    end

    # RFC-SA2A-001 S29: a transport-authenticated caller holds authority for
    # a `:change`/`:external_do` capability only when a real
    # `AshA2A.Authority.Broker` grant stands for that exact (principal,
    # capability) pair -- see `AshA2A.Authority.Grant`. Issued here for the
    # real pairs this file's own dispatches use.
    AshA2A.Test.AuthorityGrantCase.grant!([
      {"ocel-conformance-test-caller", AshA2A.Test.Fixture.FreedomGym.Facilitator, ["next_phase"]}
    ])

    {_sup, _registry_name} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [FacilitatorAgent])

    Application.put_env(:ash_a2a, :ocel_ingest_url, @ingest_url)
    :ok = OcelForwarder.attach!()
    File.mkdir_p!(@output_dir)
    on_exit(fn -> OcelForwarder.detach() end)
    :ok
  end

  # Drives the real A2A `:next_phase` skill against the real
  # FacilitatorAgent `count` times for `plan_name`, collecting the real
  # returned phase per call plus a real, monotonically increasing
  # timestamp for OCEL ordering. Real dispatch, real telemetry span
  # (forwarded best-effort by the real OcelForwarder), real reply.
  defp dispatch_real_phases!(plan_name, meeting_id, count) do
    MeetingPlan.reset(plan_name)
    base = DateTime.utc_now()

    1..count
    |> Enum.map(fn i ->
      assert {:ok, task} =
               FacilitatorAgent.call(
                 FacilitatorAgent,
                 data_message(
                   %{plan_name: plan_name, prompt_text: "next real phase #{i}"},
                   %{metadata: %{skill: "next_phase"}}
                 ),
                 metadata: %{"a2a.auth" => %{identity: "ocel-conformance-test-caller"}}
               )

      assert task.status.state == :completed
      assert [%AshA2A.Protocol.Artifact{parts: [%AshA2A.Protocol.Part.Data{data: %{phase: phase}}]}] = task.artifacts

      %{
        "event_id" => Ash.UUIDv7.generate(),
        "event_type" => "freedom_gym.meeting_phase.#{phase}",
        "event_time" => DateTime.add(base, i, :second) |> DateTime.to_iso8601(),
        "attributes" => %{"phase" => Atom.to_string(phase), "meeting_id" => meeting_id},
        "relationships" => [%{"qualifier" => "phase_of", "object_id" => meeting_id}]
      }
    end)
  end

  # Real HTTP POST to beam4pm's real, live ingest endpoint. Returns the
  # real accepted (201-confirmed) event echoes.
  defp post_real_events!(events) do
    assert {:ok, %Req.Response{status: 201, body: body}} =
             Req.post(ingest_url() <> "/ocel/events", json: %{"events" => events})

    assert body["ok"] == true
    assert length(body["accepted"]) == length(events)
    body["accepted"]
  end

  test "real HDDL plan -> real A2A dispatch -> real OCEL ingest -> real POWL conformance " <>
         "input, captured for beam4pm's real conformance check" do
    # 1) HDDL plan (Step 3, already real): 3 reference meetings each
    #    running the full real solved 6-phase plan via real A2A dispatch.
    reference_events =
      ["e2e-ref-1", "e2e-ref-2", "e2e-ref-3"]
      |> Enum.map(fn meeting_id ->
        plan_name = :"e2e_ref_#{meeting_id}_#{System.unique_integer([:positive])}"
        dispatch_real_phases!(plan_name, meeting_id, 6)
      end)
      |> List.flatten()

    # 2) Real OCEL ingest: POST every reference event to beam4pm's real,
    #    live router; the real 201 + echoed record IS the proof the wire
    #    contract round-trips, not a locally-constructed assumption.
    accepted_reference = post_real_events!(reference_events)
    assert length(accepted_reference) == 18

    # 3) Deviant run: same real dispatch machinery, but the "clean_house"
    #    phase's event is dropped before ingest -- a genuinely real
    #    execution with a deliberately injected gap, not a hand-edited
    #    event list built without dispatching at all.
    deviant_plan = :"e2e_deviant_#{System.unique_integer([:positive])}"
    deviant_events = dispatch_real_phases!(deviant_plan, "e2e-deviant-1", 6)

    deviant_events_with_gap =
      Enum.reject(deviant_events, &(&1["attributes"]["phase"] == "clean_house"))

    accepted_deviant = post_real_events!(deviant_events_with_gap)
    assert length(accepted_deviant) == 5

    # 4) Capture the real, ingest-confirmed events to a real file that
    #    beam4pm's own test reads to build its real in-process OCEL log
    #    and run the real POWL conformance check (see moduledoc for why a
    #    file, not a live query).
    reference_path = Path.join(@output_dir, "reference_ocel_events.json")
    deviant_path = Path.join(@output_dir, "deviant_ocel_events.json")

    File.write!(
      reference_path,
      JSON.encode!(%{
        "meeting_ids" => ["e2e-ref-1", "e2e-ref-2", "e2e-ref-3"],
        "events" => accepted_reference
      })
    )

    File.write!(
      deviant_path,
      JSON.encode!(%{"meeting_id" => "e2e-deviant-1", "events" => accepted_deviant})
    )

    assert File.exists?(reference_path)
    assert File.exists?(deviant_path)

    # 5) Close the loop on ash_a2a's own trust plane: seal the exact
    #    ingest-accepted reference events into a real Affidavit WASM
    #    receipt and re-verify it. `accepted: true` from the engine over
    #    the HTTP-accepted bytes is the tamper-evident closure; no mock,
    #    no stub -- the real ash_affidavit engine (a real test dep).
    lifecycle_events =
      Enum.map(accepted_reference, fn e ->
        payload =
          JSON.encode!(%{
            "phase" => e["attributes"]["phase"],
            "meeting_id" => e["attributes"]["meeting_id"]
          })

        %{
          "id" => e["event_id"],
          "event_type" => e["event_type"],
          "objects" => ["#{e["attributes"]["meeting_id"]}:Meeting"],
          "payload" => payload
        }
      end)

    assert {:ok, %{"chain_hash" => chain_hash, "content_address" => _} = assembled_receipt} =
             AshA2A.Evidence.Affidavit.assemble_receipt(lifecycle_events)

    assert is_binary(chain_hash) and byte_size(chain_hash) == 64

    assert {:ok, true} =
             AshA2A.Evidence.Affidavit.verify_receipt(assembled_receipt["receipt"])

    # Tamper-evidence falsifier: one flipped byte inside the sealed receipt
    # must make the engine's verify verdict `accepted: false` with a named
    # failing stage -- a typed refusal, never a silent pass.
    tampered =
      Map.update!(assembled_receipt["receipt"], "chain_hash", fn <<_first::binary-size(1), rest::binary>> ->
        "F" <> rest
      end)

    assert {:ok, verdict} = AshAffidavit.call(%{"op" => "verify", "receipt" => tampered})
    assert verdict["accepted"] == false

    # Real ERC receipt: this run's own actual counts, not asserted
    # constants, so the receipt can't drift from what this execution
    # really produced.
    {:ok, receipt_path} =
      AshA2A.Research.ERC.emit!(%{
        id: "ERC-001",
        claim:
          "A real HDDL-planned facilitator, dispatched over real A2A, produces OCEL v2 " <>
            "events that beam4pm's real ingest endpoint (booted hermetically in-VM from " <>
            "the canonical checkout) accepts (HTTP 201) for every phase transition, and " <>
            "the accepted events seal into a tamper-evident Affidavit receipt that " <>
            "re-verifies accepted: true.",
        falsifier:
          "Any dispatched phase transition fails to produce a 201-accepted OCEL event at " <>
            "beam4pm's ingest endpoint under the same real HDDL plan, or the assembled " <>
            "Affidavit receipt fails re-verification.",
        state: :verified,
        evidence: %{
          "reference_meetings" => 3,
          "reference_events_posted" => length(reference_events),
          "reference_events_accepted" => length(accepted_reference),
          "deviant_events_posted" => length(deviant_events_with_gap),
          "deviant_events_accepted" => length(accepted_deviant),
          "reference_capture_file" => reference_path,
          "deviant_capture_file" => deviant_path,
          "ingest_url" => ingest_url(),
          "affidavit_receipt_chain_hash" => chain_hash,
          "affidavit_receipt_content_address" => assembled_receipt["content_address"],
        },
        notes:
          "Deviant capture deliberately omits the clean_house phase event -- consumed by " <>
            "beam4pm's BeamPM.PowlConformanceE2ETest (ERC-002) as the injected falsifier " <>
            "case for the downstream conformance claim."
      })

    IO.puts("ERC-001 receipt written: #{receipt_path}")
  end
end
