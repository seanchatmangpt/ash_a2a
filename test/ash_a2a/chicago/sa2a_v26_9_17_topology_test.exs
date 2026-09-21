defmodule AshA2A.Chicago.SA2AV269_17TopologyTest do
  @moduledoc """
  Qualifies `AshA2A.Chicago.Courts.SA2AV269_17Topology` Chicago style: the real
  `AshA2A.Chicago.Runner`, real `git rev-parse`/`git status` subprocesses over
  the 11 real local sibling repositories the v26.9.17
  `test/support/hddl/sa2a_v26_9_17_dogfood/problem.hddl` names as HDDL
  `:objects`, real telemetry, and a verdict read back by the independent OCEL
  consumer from the durable artifact on disk -- zero mocks anywhere.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Chicago.Courts.SA2AV269_17Topology, as: Topology
  alias AshA2A.Chicago.{Query, Runner}

  @moduletag :tmp_dir

  describe "AshA2A.Chicago.courts/0 discovers this court" do
    test "the topology court is compiled into :ash_a2a and discoverable, not registered" do
      assert Topology in AshA2A.Chicago.courts()
      assert Topology.id() == "SA2A-TOPO"
      assert Topology.gate() == nil
      assert Topology.profile() == :core
    end
  end

  describe "the 11 real local repos this domain's :init declares as HDDL objects" do
    @tag :sibling_repos
    test "every one resolves to a real git HEAD via check_repo/1, on this machine" do
      results =
        for {obj, dir, _cap, _critical?} <- Topology.repos() do
          path = Topology.repo_path(dir)
          status = Topology.check_repo(path)

          case status do
            %{real?: true, head: head} ->
              assert Regex.match?(~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/, head),
                     "#{obj} (#{path}): reported real but head #{inspect(head)} is not a real object id"

            %{real?: false} ->
              # Report, never fail hard: this repo may genuinely not exist on
              # a different machine. On THIS machine (2026-09-17 session)
              # every one of the 11 is confirmed present -- the hard assertion
              # below is what actually enforces that, not this branch.
              IO.puts(
                "SA2A-TOPO: #{obj} (#{path}) has no real git HEAD on this machine -- reported, not failed"
              )
          end

          {obj, status.real?}
        end

      real_count = Enum.count(results, fn {_obj, real?} -> real? end)

      assert real_count == 11,
             "expected all 11 repos real on this machine, got #{real_count}: #{inspect(results)}"

      assert length(Topology.repos()) == 11
    end

    test "9 pairs are critical, 2 (unrdf/cap-runtime, wasm4pm/cap-portable-runtime) are not" do
      {critical, non_critical} = Enum.split_with(Topology.repos(), fn {_, _, _, c?} -> c? end)

      assert length(critical) == 9
      assert length(non_critical) == 2

      assert Enum.map(non_critical, fn {obj, _dir, cap, _c?} -> {obj, cap} end)
             |> Enum.sort() ==
               Enum.sort([
                 {"unrdf", "cap-runtime"},
                 {"wasm4pm", "cap-portable-runtime"}
               ])
    end

    test "check_repo/1 never raises for a path that does not exist" do
      missing =
        Path.join(
          System.tmp_dir!(),
          "sa2a-topo-does-not-exist-#{System.unique_integer([:positive])}"
        )

      assert %{real?: false, head: nil, dirty?: nil} = Topology.check_repo(missing)
    end
  end

  describe "SA2A-TOPO court end to end through the runner" do
    @tag :sibling_repos
    test "every falsifier reaches its verdict and every pass is OCEL-corroborated", %{
      tmp_dir: dir
    } do
      assert {:ok, run} = Runner.run(courts: [Topology], profile: :core, evidence_dir: dir)

      by_id = Map.new(run.results, &{&1.falsifier_id, &1})

      assert Map.keys(by_id) |> Enum.sort() == [
               "SA2A-TOPO-001",
               "SA2A-TOPO-002",
               "SA2A-TOPO-003"
             ]

      expected = %{
        "SA2A-TOPO-001" => :measured,
        "SA2A-TOPO-002" => :positive_control_passed,
        "SA2A-TOPO-003" => :falsifier_killed
      }

      for {id, verdict} <- expected do
        result = by_id[id]

        assert result.verdict == verdict,
               "#{id}: #{inspect(result.verdict)} -- #{result.detail} -- #{result.ocel_detail}"

        assert result.attempt_observed? == true, id
        assert result.ocel_corroborated? == true, "#{id}: #{result.ocel_detail}"
      end

      assert run.ocel.dropped == 0

      measurements = by_id["SA2A-TOPO-001"].measurements
      assert map_size(measurements) == 11

      for {obj, m} <- measurements do
        assert m["real"] == true, "#{obj}: #{inspect(m)}"
      end

      critical_pairs = by_id["SA2A-TOPO-002"].evidence["critical_pairs"]
      assert map_size(critical_pairs) == 9

      # The independent consumer re-derives the key facts from disk alone,
      # never from the observer's in-memory records or this court's structs.
      {:ok, index} = Query.load(Path.join(dir, "ocel.json"), run.ocel.sha256)

      assert {true, _} =
               Query.eval(
                 index,
                 "SA2A-TOPO-002",
                 {:not_observed, "chicago.topology.repo_checked", %{"real" => "false"}}
               )

      assert {true, _} =
               Query.eval(
                 index,
                 "SA2A-TOPO-003",
                 {:not_observed, "chicago.topology.repo_checked",
                  %{"repo" => "sa2a-topo-003-synthetic", "real" => "true"}}
               )

      assert {true, _} =
               Query.eval(
                 index,
                 "SA2A-TOPO-003",
                 {:observed, "chicago.topology.repo_checked",
                  %{"repo" => "sa2a-topo-003-synthetic", "real" => "false"}}
               )
    end
  end
end
