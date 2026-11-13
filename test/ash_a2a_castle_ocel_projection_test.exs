defmodule AshA2A.CastleOcelProjectionTest do
  @moduledoc """
  Court for `AshA2A.Telemetry.CastleOcel`: totality over the S42 standing
  domain, the authority/provenance invariant, determinism, and the sabotage
  twin (an unknown standing refuses with a typed error, never silently).
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.Refusal
  alias AshA2A.Telemetry.CastleOcel

  @time "2026-10-13T00:00:00Z"

  defp obs(standing, overrides \\ %{}) do
    Map.merge(
      %{standing: standing, subject_id: "subject-1", time: @time},
      overrides
    )
  end

  describe "standing_to_event/1 totality" do
    test "every S42 class plus :admitted projects to an event in the CastleOcel vocabulary" do
      castle_vocabulary =
        MapSet.new([
          "system_bootstrapped",
          "pod_provisioned",
          "container_started",
          "ggen_sync_observed",
          "activity_started",
          "activity_finished",
          "episode_recorded",
          "evidence_admitted",
          "episode_receipt_sealed",
          "refused_observation"
        ])

      for standing <- [:admitted | Refusal.classes()] do
        event_name = CastleOcel.standing_to_event(standing)

        assert is_binary(event_name),
               "#{inspect(standing)} has no mapping (totality violation)"

        assert MapSet.member?(castle_vocabulary, event_name),
               "#{inspect(standing)} maps to #{event_name}, outside the closed vocabulary"
      end
    end

    test "refused classes map to refused_observation; admitted to evidence_admitted" do
      assert CastleOcel.standing_to_event(:admitted) == "evidence_admitted"

      for class <- Refusal.refused_classes() do
        assert CastleOcel.standing_to_event(class) == "refused_observation"
      end
    end

    test "documented non-mapping: BLOCKED_*/UNSUPPORTED are observations, never refusals" do
      for class <- Refusal.blocked_classes() ++ Refusal.unsupported_classes() do
        assert CastleOcel.standing_to_event(class) == "ggen_sync_observed"
      end
    end

    test "unknown standings have no mapping" do
      for standing <- [:totally_unknown, :alive, :refused_not_a_class] do
        assert CastleOcel.standing_to_event(standing) == nil
        assert CastleOcel.standing_to_event(Atom.to_string(standing)) == nil
      end
    end
  end

  describe "projection" do
    test "admitted projects to evidence_admitted with the fixed attributes" do
      {:ok, event} = CastleOcel.project_event(obs(:admitted))

      assert event["event_type"] == "evidence_admitted"
      assert event["event_id"] == "ash-a2a-0001-evidence_admitted"
      assert event["event_time"] == @time

      assert event["attributes"] == %{
               "authority" => "none",
               "provenance" => "observation_only",
               "standing" => "admitted",
               "subject_id" => "subject-1",
               "tool" => "ash_a2a admission"
             }
    end

    test "a refused class projects to refused_observation carrying refusal_class/code" do
      {:ok, event} =
        CastleOcel.project_event(obs(:refused_authority, %{refusal_code: "authority_required"}))

      assert event["event_type"] == "refused_observation"
      assert event["attributes"]["refusal_class"] == "refused_authority"
      assert event["attributes"]["refusal_code"] == "authority_required"
      assert event["attributes"]["authority"] == "none"
    end

    test "refused_observation without a refusal_code gets the honest default" do
      {:ok, event} = CastleOcel.project_event(obs(:refused_bounds))
      assert event["attributes"]["refusal_code"] == "REFUSED"
    end

    test "blocked/unsupported classes project as ggen_sync_observed, not refusals" do
      for class <- Refusal.blocked_classes() ++ Refusal.unsupported_classes() do
        {:ok, event} = CastleOcel.project_event(obs(class))
        assert event["event_type"] == "ggen_sync_observed"
        assert event["attributes"]["refusal_class"] == Atom.to_string(class)
      end
    end
  end

  describe "authority invariant" do
    test "every projected event over the whole standing domain carries authority=none" do
      for standing <- [:admitted | Refusal.classes()] do
        {:ok, %{"events" => events}} = CastleOcel.project([obs(standing)])

        for event <- events do
          assert event["attributes"]["authority"] == "none"
          assert event["attributes"]["provenance"] == "observation_only"
        end
      end
    end
  end

  describe "determinism" do
    test "same inputs -> structurally identical envelope" do
      trace = [
        obs(:admitted),
        obs(:refused_identity, %{subject_id: "subject-2", refusal_code: "invalid_request_id"}),
        obs(:blocked_resource),
        obs(:admitted, %{subject_id: "subject-3"})
      ]

      {:ok, a} = CastleOcel.project(trace)
      {:ok, b} = CastleOcel.project(trace)

      assert a == b
      assert length(a["events"]) == 4
      assert a["events"] |> Enum.map(& &1["event_id"]) |> Enum.uniq() |> length() == 4

      assert a["objectTypes"] == [
               %{"name" => "container", "attributes" => []},
               %{"name" => "gym_act_episode", "attributes" => []},
               %{"name" => "system", "attributes" => []}
             ]

      objects = a["objects"]
      system = Enum.find(objects, &(&1["object_type"] == "system"))
      gym = Enum.find(objects, &(&1["object_type"] == "gym_act_episode"))
      container = Enum.find(objects, &(&1["object_type"] == "container"))

      assert system["object_id"] == "ash-a2a-admission"
      assert gym["object_id"] == "subject:subject-1"
      assert container["object_id"] == "ash-a2a-admission:blocked_resource"
    end
  end

  describe "sabotage twin" do
    test "an unknown standing -> typed error, never a silent projection" do
      assert {:error, {:unknown_class, :not_a_real_standing}} =
               CastleOcel.project_event(obs(:not_a_real_standing))

      assert {:error, {:unknown_class, "alive"}} = CastleOcel.project_event(obs("alive"))

      assert {:error, {:unknown_class, :not_a_real_standing}} =
               CastleOcel.project([obs(:admitted), obs(:not_a_real_standing)])
    end

    test "malformed observations refuse with typed errors" do
      assert {:error, {:invalid_observation, :nope}} = CastleOcel.project_event(:nope)

      assert {:error, {:missing_subject_id, :admitted}} =
               CastleOcel.project_event(%{standing: :admitted, time: @time})

      assert {:error, {:subject_id_not_binary, :admitted, 42}} =
               CastleOcel.project_event(obs(:admitted, %{subject_id: 42}))

      assert {:error, {:missing_time, :admitted}} =
               CastleOcel.project_event(%{standing: :admitted, subject_id: "s"})

      assert {:error, {:time_not_binary, :admitted, 0}} =
               CastleOcel.project_event(obs(:admitted, %{time: 0}))
    end
  end

  describe "envelope totality, declared attributes and E2O relationships" do
    test "the documented class count matches Refusal.classes/0 (15 + 2 + 1 = 18; 19 known)" do
      assert length(Refusal.refused_classes()) == 15
      assert length(Refusal.blocked_classes()) == 2
      assert length(Refusal.unsupported_classes()) == 1
      assert length(Refusal.classes()) == 18
      assert length(CastleOcel.known_standings()) == 19
    end

    test "projecting every Refusal class (blocked_*, unsupported_* included) yields a total envelope" do
      standings = [:admitted | Refusal.classes()]
      trace = Enum.map(standings, &obs(&1))

      assert {:ok, envelope} = CastleOcel.project(trace)
      assert length(envelope["events"]) == length(standings)

      for class <- Refusal.blocked_classes() ++ Refusal.unsupported_classes() do
        assert CastleOcel.standing_to_event(class) == "ggen_sync_observed"
      end
    end

    test "eventTypes declare the attributes events carry; every event attribute is declared" do
      {:ok, envelope} = CastleOcel.project(Enum.map([:admitted | Refusal.classes()], &obs(&1)))

      declared =
        Map.new(envelope["eventTypes"], fn %{"name" => n, "attributes" => attrs} ->
          {n, Enum.map(attrs, & &1["name"])}
        end)

      for %{"event_type" => type, "attributes" => attrs} <- envelope["events"] do
        for key <- Map.keys(attrs) do
          assert key in Map.fetch!(declared, type), "#{key} undeclared on #{type}"
        end
      end

      assert Enum.all?(envelope["eventTypes"], fn %{"attributes" => a} ->
               Enum.all?(a, &(is_binary(&1["name"]) and &1["type"] == "string"))
             end)
    end

    test "every relationship object_id exists in objects and project_event carries relationships" do
      {:ok, envelope} =
        CastleOcel.project([
          obs(:admitted),
          obs(:refused_identity, %{subject_id: "s-2"}),
          obs(:blocked_unknown, %{subject_id: "s-3"}),
          obs(:unsupported_profile, %{subject_id: "s-4"})
        ])

      object_ids = MapSet.new(envelope["objects"], & &1["object_id"])

      for event <- envelope["events"] do
        assert [_ | _] = event["relationships"]

        for %{"object_id" => id, "qualifier" => q} <- event["relationships"] do
          assert is_binary(q)
          assert MapSet.member?(object_ids, id), "#{id} not in objects"
        end

        {_type, bound_id} = CastleOcel.object_binding(event)
        assert bound_id in Enum.map(event["relationships"], & &1["object_id"])
      end

      assert {:ok, single} = CastleOcel.project_event(obs(:refused_rule))

      assert [%{"qualifier" => "observed_by"}, %{"qualifier" => "observed_subject"}] =
               single["relationships"]
    end
  end
end
