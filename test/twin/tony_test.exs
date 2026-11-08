defmodule AshA2A.Twin.TonyTest do
  use ExUnit.Case, async: true

  alias AshA2A.Twin.Tony

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
      sla_window: {DateTime.add(DateTime.utc_now(), -3600), DateTime.add(DateTime.utc_now(), 3600)},
      contractor_coi_valid: true
    }
  end

  defp edge_ticket(i) do
    %{id: "E#{i}", warranty_status: :expired, operating_hours: 9000}
  end

  # --- handle_inbound ---------------------------------------------------

  describe "handle_inbound/2" do
    test "admits when the target coordinator is under the saturation gate" do
      mesh = Tony.register_coordinator(%{}, :colo_a, @fresh_tensor)

      assert {:admit, :colo_a} =
               Tony.handle_inbound(mesh, %{coordinator_id: :colo_a})
    end

    test "sheds to the senior queue target at the saturation boundary" do
      mesh = Tony.register_coordinator(%{}, :colo_b, saturated_tensor())

      assert {:shed, {:senior_queue, :tony_relief}} =
               Tony.handle_inbound(mesh, %{coordinator_id: :colo_b})
    end

    test "unknown coordinator raises (fail-closed)" do
      assert_raise KeyError, fn ->
        Tony.handle_inbound(%{}, %{coordinator_id: :ghost})
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

      {routine, edges} = Tony.triage(tickets, now: now)

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

      assert {[^ticket], []} = Tony.triage([ticket])
    end
  end

  # --- balance ----------------------------------------------------------

  describe "balance/3" do
    test "diverts high-friction tickets from saturated coordinators to the freshest one" do
      mesh =
        %{}
        |> Tony.register_coordinator(:hot, saturated_tensor())
        |> Tony.register_coordinator(:cold, @fresh_tensor)

      tickets = [
        %{id: "T1", coordinator_id: :hot, friction: 0.9},
        %{id: "T2", coordinator_id: :hot, friction: 0.3},
        %{id: "T3", coordinator_id: :cold, friction: 0.9}
      ]

      [t1, t2, t3] = Tony.balance(tickets, mesh)

      assert t1.coordinator_id == :cold
      assert t2.coordinator_id == :hot
      assert t3.coordinator_id == :cold
    end

    test "no saturated coordinators: tickets unchanged" do
      mesh = Tony.register_coordinator(%{}, :a, @fresh_tensor)
      tickets = [%{id: "T1", coordinator_id: :a, friction: 0.99}]

      assert Tony.balance(tickets, mesh) == tickets
    end
  end
end
