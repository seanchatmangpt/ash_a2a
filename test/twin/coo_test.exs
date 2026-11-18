defmodule AshA2A.Twin.COOTest do
  use ExUnit.Case, async: true

  alias AshA2A.Twin.COO

  # --- fixtures ---------------------------------------------------------

  @fresh_tensor %{
    shift_hours_continuous: 0,
    active_leases: 0,
    error_rate: 0.0,
    heuristic_frequency: 0,
    attestation_age_sec: 0,
    financial_risk_exposure: 0
  }

  @saturated_tensor %{
    shift_hours_continuous: 10,
    active_leases: 18,
    error_rate: 0.9,
    heuristic_frequency: 10,
    attestation_age_sec: 3600,
    financial_risk_exposure: 30_000
  }

  defp saturated_tensor do
    # 0.30*(1-exp(-10/4)) + 0.25*1.0 + 0.20*0.9 + 0.10*1.0 + 0.05*0.5 + 0.10*0.6
    # = 0.2953 + 0.25 + 0.18 + 0.10 + 0.025 + 0.06 = 0.9103 > 0.7
    @saturated_tensor
  end

  defp routine_ticket(i, coordinator) do
    %{
      id: "R#{i}",
      coordinator_id: coordinator,
      warranty_status: :active,
      operating_hours: 500,
      sla_window:
        {DateTime.add(DateTime.utc_now(), -3600), DateTime.add(DateTime.utc_now(), 3600)},
      contractor_coi_valid: true
    }
  end

  defp edge_ticket(i) do
    %{id: "E#{i}", warranty_status: :expired, operating_hours: 9000}
  end

  # --- handle_inbound ---------------------------------------------------

  describe "handle_inbound/2" do
    test "admits when the target coordinator is under the saturation gate" do
      mesh = COO.register_coordinator(%{}, :colo_a, @fresh_tensor)

      assert {:admit, :colo_a} =
               COO.handle_inbound(mesh, %{coordinator_id: :colo_a})
    end

    test "sheds to the senior queue target at the saturation boundary" do
      mesh = COO.register_coordinator(%{}, :colo_b, saturated_tensor())

      assert {:shed, {:senior_queue, :coo_relief}} =
               COO.handle_inbound(mesh, %{coordinator_id: :colo_b})
    end

    test "unknown coordinator raises (fail-closed)" do
      assert_raise KeyError, fn ->
        COO.handle_inbound(%{}, %{coordinator_id: :ghost})
      end
    end
  end

  # --- triage -----------------------------------------------------------

  describe "triage/2" do
    test "partitions a realistic 40-ticket surge: 34 routine / 6 edges" do
      now = DateTime.utc_now()

      tickets =
        Enum.map(1..34, &routine_ticket(&1, :colo_a)) ++
          [
            edge_ticket(1),
            %{edge_ticket(2) | operating_hours: 9000},
            # missing fields entirely
            %{id: "E3"},
            # expired SLA
            %{
              id: "E4",
              warranty_status: :active,
              operating_hours: 100,
              sla_window: {DateTime.add(now, -7200), DateTime.add(now, -3600)},
              contractor_coi_valid: true
            },
            # COI invalid
            %{
              id: "E5",
              warranty_status: :active,
              operating_hours: 100,
              sla_window: :open,
              contractor_coi_valid: false
            },
            # hours over cap
            %{
              id: "E6",
              warranty_status: :active,
              operating_hours: 5000,
              sla_window: :open,
              contractor_coi_valid: true
            }
          ]

      {routine, edges} = COO.triage(tickets, now: now)

      assert length(routine) == 34
      assert length(edges) == 6
      assert Enum.all?(routine, &(&1.id |> String.starts_with?("R")))
      assert Enum.all?(edges, &(&1.id |> String.starts_with?("E")))
    end

    test "sla_window :open literal passes the checklist" do
      ticket = %{
        id: "R99",
        warranty_status: :active,
        operating_hours: 10,
        sla_window: :open,
        contractor_coi_valid: true
      }

      assert {[^ticket], []} = COO.triage([ticket])
    end
  end

  # --- balance ----------------------------------------------------------

  describe "balance/3" do
    test "diverts high-friction tickets from saturated coordinators to the freshest one" do
      mesh =
        %{}
        |> COO.register_coordinator(:hot, saturated_tensor())
        |> COO.register_coordinator(:cold, @fresh_tensor)

      tickets = [
        %{id: "T1", coordinator_id: :hot, friction: 0.9},
        %{id: "T2", coordinator_id: :hot, friction: 0.3},
        %{id: "T3", coordinator_id: :cold, friction: 0.9}
      ]

      [t1, t2, t3] = COO.balance(tickets, mesh)

      assert t1.coordinator_id == :cold
      assert t2.coordinator_id == :hot
      assert t3.coordinator_id == :cold
    end

    test "no saturated coordinators: tickets unchanged" do
      mesh = COO.register_coordinator(%{}, :a, @fresh_tensor)
      tickets = [%{id: "T1", coordinator_id: :a, friction: 0.99}]

      assert COO.balance(tickets, mesh) == tickets
    end
  end

  describe "triage/2 windows and boundaries" do
    @now ~U[2026-06-01 12:00:00Z]

    defp t(overrides) do
      Map.merge(
        %{
          warranty_status: :active,
          operating_hours: 500,
          sla_window: {~U[2026-06-01 00:00:00Z], ~U[2026-06-02 00:00:00Z]},
          contractor_coi_valid: true
        },
        Map.new(overrides)
      )
    end

    defp routine?(ticket, opts \\ []) do
      {r, _e} = COO.triage([ticket], Keyword.merge([now: @now], opts))
      r != []
    end

    test "sla window bounds are inclusive; one second outside escalates" do
      assert routine?(t(sla_window: {@now, ~U[2026-06-02 00:00:00Z]}))
      assert routine?(t(sla_window: {~U[2026-06-01 00:00:00Z], @now}))
      refute routine?(t(sla_window: {DateTime.add(@now, 1), ~U[2026-06-02 00:00:00Z]}))
      refute routine?(t(sla_window: {~U[2026-06-01 00:00:00Z], DateTime.add(@now, -1)}))
    end

    test "operating hours 2000 inclusive, 2001 escalates, custom max honoured, negative escalates" do
      assert routine?(t(operating_hours: 2000))
      refute routine?(t(operating_hours: 2001))
      assert routine?(t(operating_hours: 2001), max_operating_hours: 3000)
      refute routine?(t(operating_hours: -1))
      refute routine?(t(operating_hours: "500"))
    end

    test "missing or invalid fields escalate; non-map tickets escalate" do
      refute routine?(Map.delete(t([]), :warranty_status))
      refute routine?(t(warranty_status: :expired))
      refute routine?(t(contractor_coi_valid: false))
      refute routine?(Map.delete(t([]), :sla_window))
      refute routine?(t(sla_window: {1, 2}))
      {[], [:not_a_ticket]} = COO.triage([:not_a_ticket], now: @now)
    end

    test "injected now makes triage deterministic across the same ticket" do
      ticket = t(sla_window: {~U[2026-06-01 00:00:00Z], ~U[2026-06-01 06:00:00Z]})
      refute routine?(ticket)
      assert routine?(ticket, now: ~U[2026-06-01 03:00:00Z])
    end

    test "order is preserved in both partitions" do
      a = Map.put(t([]), :id, 1)
      b = Map.put(t(warranty_status: :expired), :id, 2)
      c = Map.put(t([]), :id, 3)
      d = Map.put(t(operating_hours: 9999), :id, 4)
      {r, e} = COO.triage([a, b, c, d], now: @now)
      assert Enum.map(r, & &1.id) == [1, 3]
      assert Enum.map(e, & &1.id) == [2, 4]
    end
  end

  describe "balance/3 tolerance" do
    test "tickets without :friction or :coordinator_id pass through untouched" do
      mesh =
        %{}
        |> COO.register_coordinator(:sat, saturated_tensor())
        |> COO.register_coordinator(:fresh, @fresh_tensor)

      tickets = [
        %{id: 1, coordinator_id: :sat},
        %{id: 2, friction: 0.95},
        %{id: 3},
        %{id: 4, coordinator_id: :sat, friction: 0.95},
        %{id: 5, coordinator_id: :sat, friction: nil},
        %{id: 6, coordinator_id: :sat, friction: 0.7},
        :junk
      ]

      assert [
               %{id: 1, coordinator_id: :sat},
               %{id: 2, friction: 0.95},
               %{id: 3},
               %{id: 4, coordinator_id: :fresh},
               %{id: 5, coordinator_id: :sat},
               %{id: 6, coordinator_id: :sat},
               :junk
             ] = COO.balance(tickets, mesh)
    end

    test "all coordinators saturated: tickets unchanged (no fresh target)" do
      mesh = COO.register_coordinator(%{}, :sat, saturated_tensor())
      tickets = [%{id: 1, coordinator_id: :sat, friction: 0.99}]
      assert COO.balance(tickets, mesh) == tickets
    end
  end
end
