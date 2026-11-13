# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# SPDX-layer bridge court for `AshA2A.TelemetryBridge.PPlanHazard`.
# Chicago discipline: real collaborators. The live-twin assertions run the
# REAL `AshPPlan.Telemetry.Broadcaster` (test-only dep) and assert on the real
# `%{type: :hazard_tripped, data: %HazardTripped{}}` envelope; the MAD=0 path
# is exercised through the real zero-dispersion hazard payload of the same
# vocabulary. The pack
# vocabulary check grounds against the real latency-hazard-radar
# `ontology.ttl` when present on disk, and skips LOUDLY otherwise.

defmodule AshA2A.TelemetryBridge.PPlanHazardTest do
  use ExUnit.Case, async: true

  @moduletag :pplan_court

  alias AshA2A.Protocol.Task
  alias AshA2A.TelemetryBridge.PPlanHazard

  # Compile-time live-producer detection: ash_pplan 26.11.10 (Hex) ships the
  # AshPPlan.Telemetry surface (Event.HazardTripped + Broadcaster). If the
  # resolved ash_pplan lacks it, the live tests skip LOUD (never silently).
  pplan_ebin =
    Mix.Project.build_path()
    |> Path.join("lib/ash_pplan/ebin/Elixir.AshPPlan.Telemetry.Event.beam")

  scratch_ebin = System.get_env("I3_TELEMETRY_EBIN")
  pplan_scratch_beam = scratch_ebin && Path.join(scratch_ebin, "Elixir.AshPPlan.Telemetry.Event.beam")

  @live_producer File.regular?(pplan_ebin) or (is_binary(pplan_scratch_beam) and File.regular?(pplan_scratch_beam))

  @live_skip_reason if(@live_producer,
                      do: false,
                      else: "LOUD SKIP: AshPPlan.Telemetry.Event not in resolved ash_pplan (need >= 26.11.10)"
                    )

  if not @live_producer do
    IO.warn(
      "I3 LOUD SKIP: AshPPlan.Telemetry.Event not in the resolved ash_pplan " <>
        "(need ash_pplan >= 26.11.10 under MIX_ENV=test). Live tests skipped."
    )
  end

  @pack_ontology_candidates [
    "/Users/sac/ggen-marketplace/packs/latency-hazard-radar/ontology.ttl",
    "~/ggen-marketplace/packs/latency-hazard-radar/ontology.ttl"
  ]

  @pack_ontology_path Enum.find(@pack_ontology_candidates, fn p ->
                        match?({:ok, _}, File.read(Path.expand(p)))
                      end)

  if is_nil(@pack_ontology_path) do
    IO.warn("LOUD SKIP: latency-hazard-radar ontology.ttl not found on disk; vocabulary test skipped.")
  end

  defp contract_event(overrides) do
    Map.merge(
      %{
        topic: "twin.partner.hazard",
        type: :hazard_tripped,
        run_id: "run-court-1",
        name: :partner_a,
        z: 3.1,
        threshold: 2.5,
        median: 105.0,
        mad: 7.0
      },
      Map.new(overrides)
    )
  end

  defp fresh_task, do: Task.new(id: "tsk-hazard-court")

  # Live-path helpers: all upstream calls are dynamic (apply) so the court
  # compiles cleanly under a Hex pin that predates the telemetry surface.
  defp live_mod(name), do: String.to_atom("Elixir.AshPPlan.Telemetry." <> name)

  defp hazard_struct(fields) when is_list(fields) do
    mod = live_mod("Event.HazardTripped")
    struct(mod, fields)
  end

  defp start_broadcaster(name) do
    mod = live_mod("Broadcaster")
    pid = start_supervised!({mod, [name: name]})
    {:ok, pid}
  end

  defp broadcaster_subscribe(server, topic) do
    apply(live_mod("Broadcaster"), :subscribe, [server, topic])
  end

  defp broadcaster_broadcast(server, topic, data) do
    apply(live_mod("Broadcaster"), :broadcast, [server, topic, data])
  end

  # --- (4) shared vocabulary vs the pack ontology ---------------------------

  describe "shared vocabulary with latency-hazard-radar ontology" do
    # A missing pack on disk is a LOUD skip (IO.warn above + skip reason),
    # never a silent pass and never an assertion failure of the pack's absence.
    @tag skip: if(is_nil(@pack_ontology_path), do: "LOUD SKIP: pack ontology.ttl not on disk", else: false)
    test "bridge defaults mirror the pack's pinned threshold and refusal atom" do
      source = File.read!(Path.expand(@pack_ontology_path))

      assert source =~ "urn:latency-hazard-radar:", "pack namespace declaration missing"

      # lhr:hazardThreshold default = 2.5 (lhr:default-policy individual)
      assert source =~ ~r/hazardThreshold "2\.5"/, "pack default hazardThreshold drifted from 2.5"

      # lhr:refusalAtom = insufficient_dispersion
      assert source =~ "insufficient_dispersion", "pack refusalAtom drifted"

      # vocabulary the bridge mirrors is still declared
      assert source =~ "triagePrompt"
      assert source =~ "medianMillis"
      assert source =~ "madMillis"
    end
  end

  # --- (3) trip / no-trip / refusal court -----------------------------------

  describe "trip law (strictly greater than threshold)" do
    test "z above threshold annotates the task metadata" do
      task = fresh_task()

      assert {:ok, annotated} = PPlanHazard.annotate(task, contract_event(z: 3.1, threshold: 2.5))
      assert annotated.metadata["hazard"] == "hazard: z=3.1, threshold=2.5"
      assert annotated.id == task.id
      assert annotated.status.state == :submitted
    end

    test "z below threshold returns the task unchanged (no annotation)" do
      task = fresh_task()

      assert {:ok, unchanged} = PPlanHazard.annotate(task, contract_event(z: 1.2, threshold: 2.5))
      assert unchanged == task
      assert unchanged.metadata == %{}
    end

    test "z exactly at threshold does NOT trip" do
      task = fresh_task()

      assert {:ok, unchanged} = PPlanHazard.annotate(task, contract_event(z: 2.5, threshold: 2.5))
      assert unchanged.metadata == %{}
    end

    test "integer z and threshold compare and format without float artifacts" do
      task = fresh_task()

      assert {:ok, annotated} = PPlanHazard.annotate(task, contract_event(z: 5, threshold: 3))
      assert annotated.metadata["hazard"] == "hazard: z=5, threshold=3"
    end

    test "annotation preserves pre-existing task metadata" do
      task = %{fresh_task() | metadata: %{"tenant" => "acme"}}

      assert {:ok, annotated} = PPlanHazard.annotate(task, contract_event(z: 4.0))
      assert annotated.metadata["tenant"] == "acme"
      assert annotated.metadata["hazard"] == "hazard: z=4.0, threshold=2.5"
    end
  end

  describe "malformed events are typed refusals" do
    test "non-number z, non-number threshold, nil z, non-number mad" do
      task = fresh_task()

      for bad <- [[z: "3"], [z: nil], [threshold: nil], [threshold: "2.5"], [mad: "7"]] do
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:refused, :invalid_event} = PPlanHazard.annotate(task, contract_event(bad))
        end)
      end

      assert {:refused, :invalid_event} =
               ExUnit.CaptureLog.with_log(fn -> PPlanHazard.annotate(task, %{}) end) |> elem(0)
    end

    test "missing :mad still annotates on trip (mad is optional)" do
      task = fresh_task()
      event = Map.delete(contract_event(z: 4.0), :mad)
      assert {:ok, annotated} = PPlanHazard.annotate(task, event)
      assert annotated.metadata["hazard"] == "hazard: z=4.0, threshold=2.5"
    end

    test "annotation tolerates nil task metadata and non-number format input" do
      task = %{fresh_task() | metadata: nil}
      assert {:ok, annotated} = PPlanHazard.annotate(task, contract_event(z: 4.0))
      assert annotated.metadata["hazard"] =~ "hazard: z=4.0"
      assert PPlanHazard.annotation(%{z: :weird}, 2.5) == "hazard: z=:weird, threshold=2.5"
    end
  end

  describe "MAD = 0 insufficient-dispersion refusal" do
    test "mad: 0 is a typed refusal, no annotation, typed log line" do
      task = fresh_task()
      event = contract_event(z: 99.0, mad: 0)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:refused, :insufficient_dispersion} = PPlanHazard.annotate(task, event)
        end)

      assert log =~ "insufficient_dispersion"
      assert task.metadata == %{}
    end

    test "explicit error field is also refused (typed path)" do
      task = fresh_task()
      event = contract_event(error: :insufficient_dispersion)

      assert {:refused, :insufficient_dispersion} = PPlanHazard.annotate(task, event)
      assert task.metadata == %{}
    end
  end

  # --- (1) live twin consumption --------------------------------------------

  describe "live AshPPlan.Telemetry.Broadcaster consumption" do
    @tag skip: @live_skip_reason
    test "real hazard envelope annotates with the live z and threshold" do
      {:ok, _pid} = start_broadcaster(:i3_broadcaster_a)
      topic = :i3_hazard_topic

      broadcaster_subscribe(:i3_broadcaster_a, topic)

      event_data =
        hazard_struct(
          run_id: "run-live-1",
          hazard: %{z: 3.1, threshold: 2.5, median: 105.0, mad: 7.0}
        )

      broadcaster_broadcast(:i3_broadcaster_a, topic, event_data)

      assert_receive {:ash_pplan_telemetry, envelope}, 2_000
      assert envelope.type == :hazard_tripped
      assert envelope.run_id == "run-live-1"
      assert envelope.data.hazard.z == 3.1

      contract = %{
        topic: envelope.topic,
        type: envelope.type,
        run_id: envelope.run_id,
        z: envelope.data.hazard.z,
        threshold: envelope.data.hazard.threshold,
        median: envelope.data.hazard.median,
        mad: envelope.data.hazard.mad
      }

      task = fresh_task()
      assert {:ok, annotated} = PPlanHazard.annotate(task, contract)
      assert annotated.metadata["hazard"] == "hazard: z=3.1, threshold=2.5"
    end

    @tag skip: @live_skip_reason
    test "envelope seq is monotonic per topic and stamped with emitted_at" do
      {:ok, _pid} = start_broadcaster(:i3_broadcaster_b)
      topic = :i3_seq_topic
      broadcaster_subscribe(:i3_broadcaster_b, topic)

      data = hazard_struct(run_id: "run-live-seq", hazard: %{z: 9.0, threshold: 2.5, mad: 1.0})
broadcaster_broadcast(:i3_broadcaster_b, topic, data)
broadcaster_broadcast(:i3_broadcaster_b, topic, data)

      assert_receive {:ash_pplan_telemetry, e1}, 2_000
      assert_receive {:ash_pplan_telemetry, e2}, 2_000
      assert e2.seq == e1.seq + 1
      assert %DateTime{} = e1.emitted_at
    end

    @tag skip: @live_skip_reason
    test "real zero-dispersion payload refuses with no annotation" do
      {:ok, _pid} = start_broadcaster(:i3_broadcaster_c)
      topic = :i3_flat_topic
      broadcaster_subscribe(:i3_broadcaster_c, topic)

      data =
        hazard_struct(
          run_id: "run-live-flat",
          hazard: %{z: 0.0, threshold: 2.5, median: 50.0, mad: 0}
        )

broadcaster_broadcast(:i3_broadcaster_c, topic, data)
      assert_receive {:ash_pplan_telemetry, envelope}, 2_000
      assert envelope.type == :hazard_tripped

      contract = %{
        topic: envelope.topic,
        type: envelope.type,
        run_id: envelope.run_id,
        z: envelope.data.hazard.z,
        threshold: envelope.data.hazard.threshold,
        median: envelope.data.hazard.median,
        mad: envelope.data.hazard.mad
      }

      task = fresh_task()
      assert {:refused, :insufficient_dispersion} = PPlanHazard.annotate(task, contract)
      assert task.metadata == %{}
    end
  end
end
