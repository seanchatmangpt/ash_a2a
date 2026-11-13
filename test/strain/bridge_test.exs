defmodule AshA2A.Strain.BridgeTest do
  use ExUnit.Case, async: true

  alias AshA2A.Strain.{Bridge, Tensor}

  describe "record_observation/3 dimension mapping" do
    test "ticket_assigned increments active_leases" do
      ms = Bridge.new_mesh_state([:a])

      ms = Bridge.record_observation(ms, :a, %{type: :ticket_assigned})
      ms = Bridge.record_observation(ms, :a, %{type: :ticket_assigned})

      assert ms[:a].tensor.active_leases == 2
    end

    test "ticket_completed decrements active_leases with floor at 0" do
      ms = Bridge.new_mesh_state([:a])

      ms = Bridge.record_observation(ms, :a, %{type: :ticket_completed})

      assert ms[:a].tensor.active_leases == 0

      ms = Bridge.record_observation(ms, :a, %{type: :ticket_assigned})
      ms = Bridge.record_observation(ms, :a, %{type: :ticket_completed})

      assert ms[:a].tensor.active_leases == 0
    end

    test "challenge_received from Vince increments heuristic_frequency" do
      ms = Bridge.new_mesh_state([:a])

      ms =
        Enum.reduce(1..3, ms, fn _, acc ->
          Bridge.record_observation(acc, :a, %{
            type: :challenge_received,
            source: :vince,
            heuristic: :gaslight_pattern
          })
        end)

      assert ms[:a].tensor.heuristic_frequency == 3
    end

    test "error_reported feeds the rolling window and error_rate" do
      ms = Bridge.new_mesh_state([:a])

      ms =
        ms
        |> Bridge.record_observation(:a, %{type: :error_reported, error: true})
        |> Bridge.record_observation(:a, %{type: :error_reported, error: false})
        |> Bridge.record_observation(:a, %{type: :error_reported, error: true})

      assert ms[:a].error_window == [1, 0, 1]
      assert_in_delta Bridge.error_rate(ms, :a), 2 / 3, 1.0e-9
    end

    test "error window is capped at 20 entries" do
      ms =
        Enum.reduce(1..25, Bridge.new_mesh_state([:a]), fn _, acc ->
          Bridge.record_observation(acc, :a, %{type: :error_reported, error: true})
        end)

      assert length(ms[:a].error_window) == 20
      assert ms[:a].tensor.error_rate == 1.0
    end

    test "clock_hour advances shift_hours via the decay input" do
      ms = Bridge.new_mesh_state([:a])

      ms =
        Enum.reduce(1..8, ms, fn _, acc ->
          Bridge.record_observation(acc, :a, %{type: :clock_hour, hours: 1})
        end)

      assert ms[:a].tensor.shift_hours_continuous == 8
      # circadian decay 1 - exp(-8/4) ~= 0.8647
      decay = Bridge.circadian_decay(ms, :a)
      assert decay > 0.85 and decay < 0.87
    end

    test "unknown event type raises" do
      ms = Bridge.new_mesh_state([:a])

      assert_raise ArgumentError, ~r/unknown observation type/, fn ->
        Bridge.record_observation(ms, :a, %{type: :mystery_event})
      end
    end
  end

  describe "route/2" do
    test "picks the min-strain coordinator among candidates" do
      fresh = Bridge.new_mesh_state([:fresh, :loaded])

      loaded =
        Enum.reduce(1..6, fresh, fn _, acc ->
          Bridge.record_observation(acc, :loaded, %{type: :ticket_assigned})
        end)

      assert {:assign, :fresh} = Bridge.route(%{candidates: [:fresh, :loaded]}, loaded)
    end

    test "sheds with reason when all candidates are saturated" do
      ms =
        Enum.reduce(1..12, Bridge.new_mesh_state([:a]), fn _, acc ->
          acc
          |> Bridge.record_observation(:a, %{type: :ticket_assigned})
          |> Bridge.record_observation(:a, %{type: :clock_hour, hours: 1})
          |> Bridge.record_observation(:a, %{type: :error_reported, error: true})
        end)

      assert {:shed, {:senior_queue, :all_saturated}} =
               Bridge.route(%{candidates: [:a]}, ms)
    end

    test "unknown candidate ids are skipped, not crashed" do
      ms = Bridge.new_mesh_state([:a])
      assert {:assign, :a} = Bridge.route(%{candidates: [:ghost, :a]}, ms)

      assert {:shed, {:senior_queue, _}} = Bridge.route(%{candidates: [:ghost]}, ms)
    end
  end

  describe "fatigue-diversion invariant court" do
    setup do
      # tired: shift past the 0.85 decay threshold, error drift rising
      tired =
        Enum.reduce(1..12, Bridge.new_mesh_state([:tired, :fresh]), fn _, acc ->
          Bridge.record_observation(acc, :tired, %{type: :ticket_assigned})
        end)

      tired =
        Enum.reduce(1..14, tired, fn i, acc ->
          acc
          |> Bridge.record_observation(:tired, %{type: :clock_hour, hours: 0.65})
          |> Bridge.record_observation(:tired, %{type: :error_reported, error: i > 4})
        end)

      assert Bridge.circadian_decay(tired, :tired) > 0.85
      assert Bridge.error_drift_rising?(tired, :tired)

      tired =
        Enum.reduce(1..3, tired, fn _, acc ->
          Bridge.record_observation(acc, :tired, %{type: :ticket_completed})
        end)

      %{mesh: tired}
    end

    test "deep decay + rising drift diverts high-friction ticket to fresh coordinator", %{
      mesh: mesh
    } do
      ticket = %{friction: 0.9, candidates: [:tired, :fresh]}

      assert {:assign, :fresh} = Bridge.route(ticket, mesh)
    end

    test "deep decay alone (stable errors) does NOT divert", %{mesh: mesh} do
      # settle the window: half errors, uniform -> drift not rising
      mesh =
        Enum.reduce(1..20, mesh, fn _, acc ->
          Bridge.record_observation(acc, :tired, %{type: :error_reported, error: true})
        end)

      # 12 leases -> saturated; complete 4 to drop below the gate
      mesh =
        Enum.reduce(1..4, mesh, fn _, acc ->
          Bridge.record_observation(acc, :tired, %{type: :ticket_completed})
        end)

      assert Bridge.circadian_decay(mesh, :tired) > 0.85
      refute Bridge.error_drift_rising?(mesh, :tired)
      assert Tensor.hyperplane_check(mesh[:tired].tensor) == :ok

      # eligibility invariant: non-fatigued deep-decay coordinator may receive
      # the ticket (min-strain may still prefer :fresh, which is lawful)
      assert {:assign, :tired} = Bridge.route(%{friction: 0.9, candidates: [:tired]}, mesh)
    end

    test "50-ticket sweep: every ticket ends assigned or shed-with-reason, none dropped", %{
      mesh: mesh
    } do
      # seeded: deterministic across runs (no global :rand state)
      seed = :rand.seed_s(:exsss, {101, 102, 103})

      {tickets, _} =
        Enum.map_reduce(1..50, seed, fn i, st ->
          {f, st2} = :rand.uniform_s(st)
          {%{id: i, friction: f, candidates: [:tired, :fresh]}, st2}
        end)

      outcomes = Enum.map(tickets, &Bridge.route(&1, mesh))

      assert length(outcomes) == 50

      Enum.each(outcomes, fn
        {:assign, id} -> assert id in [:tired, :fresh]
        {:shed, {:senior_queue, reason}} -> assert not is_nil(reason)
      end)

      assert Enum.all?(outcomes, fn
               {:assign, _} -> true
               {:shed, _} -> true
               _ -> false
             end)
    end

    test "all-fatigued high-friction sheds with the friction-specific reason" do
      ms =
        Enum.reduce(1..14, Bridge.new_mesh_state([:only]), fn i, acc ->
          acc
          |> Bridge.record_observation(:only, %{type: :clock_hour, hours: 0.65})
          |> Bridge.record_observation(:only, %{type: :error_reported, error: i > 4})
        end)

      assert Bridge.circadian_decay(ms, :only) > 0.85
      assert Bridge.error_drift_rising?(ms, :only)

      assert {:shed, {:senior_queue, {:all_saturated_or_fatigued, :high_friction}}} =
               Bridge.route(%{friction: 0.95, candidates: [:only]}, ms)
    end
  end

  test "termination by construction: routing 200 tickets over a finite mesh returns exactly 200 outcomes" do
    ms = Bridge.new_mesh_state([:a, :b, :c])

    outcomes =
      Enum.map(1..200, fn i ->
        Bridge.route(%{id: i, friction: rem(i, 4) / 4, candidates: [:a, :b, :c]}, ms)
      end)

    assert length(outcomes) == 200

    assert Enum.all?(outcomes, fn
             {:assign, _} -> true
             {:shed, {:senior_queue, _}} -> true
           end)
  end

  describe "event contract and validation" do
    test "error flag: true/1 count, false/0/nil/missing do not; other values raise" do
      ms = Bridge.new_mesh_state([:c])

      rate = fn events ->
        events
        |> Enum.reduce(
          ms,
          &Bridge.record_observation(&2, :c, Map.put(&1, :type, :error_reported))
        )
        |> Bridge.error_rate(:c)
      end

      assert rate.([%{error: true}, %{error: 1}]) == 1.0
      assert rate.([%{error: false}, %{error: 0}, %{error: nil}, %{}]) == 0.0
      assert rate.([%{error: true}, %{}]) == 0.5

      assert_raise ArgumentError, ~r/invalid error flag/, fn -> rate.([%{error: "yes"}]) end
    end

    test "clock_hour :hours validation" do
      ms = Bridge.new_mesh_state([:c])

      for bad <- [-1, "2", nil, :x] do
        assert_raise ArgumentError, ~r/non-negative number/, fn ->
          Bridge.record_observation(ms, :c, %{type: :clock_hour, hours: bad})
        end
      end

      ms2 = Bridge.record_observation(ms, :c, %{type: :clock_hour})
      assert ms2[:c].tensor.shift_hours_continuous == 1
      ms3 = Bridge.record_observation(ms2, :c, %{type: :clock_hour, hours: 0})
      assert ms3[:c].tensor.shift_hours_continuous == 1
    end

    test "unregistered ids read consistently as zero/false" do
      ms = Bridge.new_mesh_state([:known])
      assert Bridge.circadian_decay(ms, :ghost) == 0.0
      assert Bridge.error_rate(ms, :ghost) == 0.0
      refute Bridge.error_drift_rising?(ms, :ghost)
    end

    test "empty candidates shed with :no_candidates, distinct from saturation" do
      ms = Bridge.new_mesh_state([:a])
      assert {:shed, {:senior_queue, :no_candidates}} = Bridge.route(%{candidates: []}, ms)

      assert {:shed, {:senior_queue, :no_candidates}} =
               Bridge.route(%{friction: 0.9, candidates: []}, ms)

      # only-unknown candidates keep the generic reason
      assert {:shed, {:senior_queue, :all_saturated}} = Bridge.route(%{candidates: [:ghost]}, ms)
      # empty mesh, default candidates
      assert {:shed, {:senior_queue, :no_candidates}} = Bridge.route(%{}, Bridge.new_mesh_state())
    end
  end

  describe "error_drift_rising?/2 direct" do
    defp with_errors(flags) do
      Enum.reduce(flags, Bridge.new_mesh_state([:c]), fn f, acc ->
        Bridge.record_observation(acc, :c, %{type: :error_reported, error: f})
      end)
    end

    test "needs at least 4 outcomes" do
      refute Bridge.error_drift_rising?(with_errors([false, false, true]), :c)
      assert Bridge.error_drift_rising?(with_errors([false, false, true, true]), :c)
    end

    test "rising when recent half has more errors than older half" do
      assert Bridge.error_drift_rising?(with_errors([false, false, false, true, true, true]), :c)
    end

    test "falling or flat is not rising" do
      refute Bridge.error_drift_rising?(with_errors([true, true, true, false, false, false]), :c)
      refute Bridge.error_drift_rising?(with_errors([true, false, true, false]), :c)
      refute Bridge.error_drift_rising?(with_errors([false, false, false, false]), :c)
    end
  end

  describe "fatigue gate: negatives and breach" do
    defp tired_mesh(error_flags) do
      ms = Bridge.new_mesh_state([:tired, :fresh])

      ms =
        Enum.reduce(1..14, ms, fn _, acc ->
          Bridge.record_observation(acc, :tired, %{type: :clock_hour, hours: 0.65})
        end)

      Enum.reduce(error_flags, ms, fn f, acc ->
        Bridge.record_observation(acc, :tired, %{type: :error_reported, error: f})
      end)
    end

    test "fatigued + high friction diverts; fatigued + low friction does NOT" do
      ms = tired_mesh(List.duplicate(false, 4) ++ List.duplicate(true, 8))
      assert Bridge.circadian_decay(ms, :tired) > 0.85
      assert Bridge.error_drift_rising?(ms, :tired)

      # low friction: tired coordinator is eligible; min-strain still picks the
      # zero-load :fresh, so offer :tired alone to prove eligibility
      assert {:assign, :tired} = Bridge.route(%{friction: 0.7, candidates: [:tired]}, ms)
      assert {:assign, :tired} = Bridge.route(%{friction: 0.1, candidates: [:tired]}, ms)
      assert {:assign, :tired} = Bridge.route(%{candidates: [:tired]}, ms)

      # high friction: diverted
      assert {:assign, :fresh} = Bridge.route(%{friction: 0.71, candidates: [:tired, :fresh]}, ms)
    end

    test "saturation breach sheds even for low friction" do
      ms =
        Enum.reduce(1..30, tired_mesh(List.duplicate(true, 6)), fn _, acc ->
          Bridge.record_observation(acc, :tired, %{type: :ticket_assigned})
        end)

      assert {:breach, _} = Tensor.hyperplane_check(ms[:tired].tensor)

      assert {:shed, {:senior_queue, :all_saturated}} =
               Bridge.route(%{friction: 0.0, candidates: [:tired]}, ms)
    end
  end
end
