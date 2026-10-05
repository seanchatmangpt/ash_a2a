# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Chicago.ClosureTest do
  # DB-free: reads compiled BEAM abstract code only.
  use ExUnit.Case, async: true

  alias AshA2A.Chicago.Closure
  alias AshA2A.ClosureFixtures.{Bypass, Dynamic, FunRefBypass, Kernel, ReadOnly, Sink}

  @effectors [%{module: Sink, functions: [:write], kind: :fixture_sink, wrapper: false}]
  @allowed [Kernel]

  defp opts(extra \\ []),
    do: Keyword.merge([effectors: @effectors, allowed_callers: @allowed], extra)

  describe "fixture anti-vacuity (planted bypass)" do
    test "enforce mode refuses the planted bypass and names caller + chain" do
      assert {:refused, report} = Closure.run([Kernel, Sink, Bypass], opts(mode: :enforce))
      assert report.verdict == "violations"
      assert [edge] = report.violating_edges
      assert edge.caller == "AshA2A.ClosureFixtures.Bypass.helper/1"
      assert edge.callee == "AshA2A.ClosureFixtures.Sink.write/1"

      assert edge.chain == [
               "AshA2A.ClosureFixtures.Bypass.entry/1",
               "AshA2A.ClosureFixtures.Bypass.helper/1",
               "AshA2A.ClosureFixtures.Sink.write/1"
             ]
    end

    test "removing the plant makes enforce pass" do
      assert {:ok, report} = Closure.run([Kernel, Sink], opts(mode: :enforce))
      assert report.verdict == "clean"
      assert report.violating_edges == []
    end

    test "report mode returns violations as data without refusing" do
      assert {:ok, report} = Closure.run([Kernel, Sink, Bypass], opts(mode: :report))
      assert report.verdict == "violations"
      assert length(report.violating_edges) == 1
    end

    test "a remote function reference is an edge" do
      assert {:refused, report} = Closure.run([Sink, FunRefBypass], opts(mode: :enforce))

      assert [%{edge_kind: "fun_ref", caller: "AshA2A.ClosureFixtures.FunRefBypass.writer/0"}] =
               report.violating_edges
    end

    test "classification is per function: a non-effector function is not an edge" do
      assert {:ok, %{verdict: "clean"}} = Closure.run([Sink, ReadOnly], opts(mode: :enforce))
    end

    test "allowed set accepts module-name prefixes" do
      assert {:ok, %{verdict: "clean"}} =
               Closure.run(
                 [Sink, Kernel],
                 opts(mode: :enforce, allowed_callers: ["AshA2A.ClosureFixtures.Ker"] ++ [Kernel])
               )

      assert {:refused, _} =
               Closure.run(
                 [Sink, Bypass],
                 opts(mode: :enforce, allowed_callers: ["AshA2A.ClosureFixtures.Byp"])
               )
    end
  end

  describe "unresolved dynamic edges" do
    test "apply/3 and module-variable calls are UNRESOLVED edges, refused in enforce" do
      assert {:refused, report} = Closure.run([Dynamic], opts(mode: :enforce))
      kinds = report.unresolved_edges |> Enum.map(&{&1.caller, &1.edge_kind}) |> Enum.sort()

      assert kinds == [
               {"AshA2A.ClosureFixtures.Dynamic.via_apply/3", "dynamic_apply"},
               {"AshA2A.ClosureFixtures.Dynamic.via_module_var/2", "dynamic_remote"}
             ]
    end

    test "unresolved: :report keeps them as data without refusing" do
      assert {:ok, report} = Closure.run([Dynamic], opts(mode: :enforce, unresolved: :report))
      assert length(report.unresolved_edges) == 2
    end
  end

  describe "report encoding" do
    test "JSON round-trips with the violating edge" do
      {:ok, report} = Closure.run([Sink, Bypass], opts())
      decoded = report |> Closure.to_json() |> Jason.decode!()
      assert decoded["schema"] == "ash_a2a.chicago.closure/v1"

      assert [%{"caller" => "AshA2A.ClosureFixtures.Bypass.helper/1"}] =
               decoded["violating_edges"]
    end
  end

  setup_all do
    modules = Closure.app_modules()
    {:ok, report} = Closure.run(modules, mode: :report)
    %{modules: modules, report: report}
  end

  describe "real tree" do
    test "fixtures are excluded from the analysed tree", %{modules: modules} do
      refute Bypass in modules
      assert AshA2A.Agent in modules
    end

    test "migrated: agent observe path uses dispatch_observe, no raw Dispatcher.dispatch edge", %{
      report: r
    } do
      # W4B moved AshA2A.Agent's :observe path from Dispatcher.dispatch to the explicit
      # observation-only entry Dispatcher.dispatch_observe; the raw edge must not come back.
      refute Enum.any?(r.violating_edges, fn e ->
               e.caller_module == "AshA2A.Agent" and
                 String.starts_with?(e.callee, "AshA2A.Dispatcher.dispatch/")
             end)
    end

    test "known bypass: on_cancel apply is an UNRESOLVED dynamic_apply in Agent", %{report: r} do
      assert Enum.any?(r.unresolved_edges, fn e ->
               e.caller == "AshA2A.Agent.invoke_on_cancel_hook/5" and
                 e.edge_kind == "dynamic_apply"
             end)
    end

    test "known bypass: push_delivery Req.post", %{report: r} do
      assert Enum.any?(r.violating_edges, fn e ->
               e.caller_module == "AshA2A.A2ATransport.PushDelivery" and e.callee == "Req.post/2"
             end)
    end

    test "known bypass: ocel_forwarder Req.post", %{report: r} do
      assert Enum.any?(r.violating_edges, fn e ->
               e.caller_module == "AshA2A.Telemetry.OcelForwarder" and
                 String.starts_with?(e.callee, "Req.post/")
             end)
    end

    test "report mode is data; enforce refuses the current tree", %{modules: modules, report: r} do
      assert r.mode == "report"
      assert r.summary.violating_edges > 0
      assert {:refused, %{mode: "enforce"}} = Closure.run(modules, mode: :enforce)
    end

    test "kernel-internal callers are never violators", %{report: r} do
      refute Enum.any?(
               r.violating_edges,
               &String.starts_with?(&1.caller_module, "AshA2A.ConsequenceKernel")
             )
    end
  end
end
