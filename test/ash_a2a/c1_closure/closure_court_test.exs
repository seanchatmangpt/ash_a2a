defmodule AshA2A.C1Closure.ClosureCourtTest do
  @moduledoc """
  Kernel-only DO closure court over the real compiled application (BEAM abstract code), plus
  anti-vacuity: a mutant module compiled to a real `.beam` that calls a DO entry directly must
  turn the court red. No doubles.
  """
  use ExUnit.Case, async: false

  alias AshA2A.Chicago.Fixtures.Brce.Ledger
  alias AshA2A.ConsequenceKernel.ClosureCourt
  alias AshA2A.ConsequenceKernel.Closure.Exceptions

  @moduletag timeout: 600_000

  defp mutant(name, body), do: mutant_named(Module.concat(AshA2A.C1Closure.Mutants, name), body)

  defp mutant_named(module, body) do
    dir = Path.join(System.tmp_dir!(), "c1_closure_mutants_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    previous = Code.get_compiler_option(:debug_info)
    Code.put_compiler_option(:debug_info, true)

    [{^module, bin}] =
      Code.compile_string("""
      defmodule #{inspect(module)} do
        def go(msg), do: #{body}
      end
      """)

    Code.put_compiler_option(:debug_info, previous)
    path = Path.join(dir, "#{module}.beam")
    File.write!(path, bin)
    {:module, ^module} = :code.load_binary(module, String.to_charlist(path), bin)
    on_exit(fn -> File.rm_rf(dir) end)
    module
  end

  @core [
    AshA2A.Agent,
    AshA2A.CommandBus,
    AshA2A.Dispatcher,
    AshA2A.ConsequenceKernel.W4.DispatchInversion
  ]

  describe "whole application" do
    test "report/0 has zero violating edges and every exception is observed" do
      report = ClosureCourt.report()
      assert report.violating_edges == [], inspect(report.violating_edges, limit: 20)
      assert report.verdict == "closed"
      assert report.sole_path == "AshA2A.ConsequenceKernel.Runtime.Pipeline"
      assert report.kernel_gateways == ["AshA2A.ConsequenceKernel.W4.DispatchInversion.execute/2"]
      assert length(report.typed_exceptions) >= length(Exceptions.edges())
    end

    test "c1.closure_report conformance check passes on the real court" do
      assert {:pass, _} = AshA2A.SA2A.Conformance.Checks.C1.closure_report(%{})
    end

    test "every typed exception names an existing court file" do
      for exc <- Exceptions.edges() ++ Exceptions.dynamic_sites() do
        assert File.exists?(exc.court), "#{exc.id}: missing court #{exc.court}"
      end
    end

    test "CommandBus has no direct Dispatcher edge (routes through the kernel inversion)" do
      report = ClosureCourt.report(modules: [AshA2A.CommandBus])
      refute Enum.any?(report.violating_edges, &(&1[:callee] =~ "AshA2A.Dispatcher"))
    end
  end

  describe "anti-vacuity mutations" do
    test "a direct Dispatcher.dispatch from a random module is a violating edge" do
      m = mutant("DirectDispatch", "AshA2A.Dispatcher.dispatch(:record, msg, Elixir.Nope)")
      report = ClosureCourt.report(modules: @core, extra_modules: [m])
      assert report.verdict == "violations"

      assert Enum.any?(report.violating_edges, fn e ->
               e[:caller] == "#{inspect(m)}.go/1" and e[:callee] =~ "Dispatcher.dispatch/3"
             end)
    end

    test "a direct dispatch_observe, BrceAnchor.put, C2 actuator and Ash write are each caught" do
      for {name, body, callee} <- [
            {"Observe", "AshA2A.Dispatcher.dispatch_observe(:x, msg, Nope)", "dispatch_observe"},
            {"Anchor", "AshA2A.BrceAnchor.put(msg)", "BrceAnchor.put"},
            {"C2", "AshA2A.C2.Actuator.execute(msg, msg, msg, msg, msg)", "C2.Actuator.execute"},
            {"Ash", "Ash.create(msg)", "Ash.create"}
          ] do
        m = mutant(name, body)
        report = ClosureCourt.report(modules: @core, extra_modules: [m])
        assert report.verdict == "violations", name
        assert Enum.any?(report.violating_edges, &((&1[:callee] || "") =~ callee)), name
      end
    end

    test "a function reference to the entry point is an edge" do
      m = mutant("FunRef", "&AshA2A.Dispatcher.dispatch/3")
      report = ClosureCourt.report(modules: @core, extra_modules: [m])
      assert report.verdict == "violations"
    end

    test "a module without debug info cannot hide an edge: it is a violation, not skipped" do
      module = Module.concat(AshA2A.C1Closure.Mutants, "NoDebug")
      previous = Code.get_compiler_option(:debug_info)
      Code.put_compiler_option(:debug_info, false)

      [{^module, bin}] =
        Code.compile_string(
          "defmodule #{inspect(module)} do\n def go(m), do: AshA2A.Dispatcher.dispatch(:x, m, N)\nend"
        )

      Code.put_compiler_option(:debug_info, previous)
      dir = Path.join(System.tmp_dir!(), "c1_nodebug_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      path = Path.join(dir, "#{module}.beam")
      File.write!(path, bin)
      {:module, ^module} = :code.load_binary(module, String.to_charlist(path), bin)
      on_exit(fn -> File.rm_rf(dir) end)

      report = ClosureCourt.report(modules: @core, extra_modules: [module])
      assert Enum.any?(report.violating_edges, &(&1.violation == "unanalyzable_module"))
    end

    test "a stale exception is a violation (dead exceptions cannot stay listed)" do
      report = ClosureCourt.report(modules: [AshA2A.C2.Actuator], stale_check: true)
      assert Enum.any?(report.violating_edges, &(&1.violation == "stale_exception"))
    end

    test "removing the mutant restores the closed verdict on the same module set" do
      report = ClosureCourt.report(modules: @core)
      assert report.violating_edges == []
    end
  end

  describe "prefix exemptions are not blanket trust (D1/D2/D3)" do
    @do_bodies [
      {"C2Actuator", "AshA2A.C2.Actuator.execute(msg, msg, msg, msg, msg)"},
      {"Anchor", "AshA2A.BrceAnchor.put(msg)"},
      {"AshWrite", "Ash.create(msg)"},
      {"Dispatch", "AshA2A.Dispatcher.dispatch(:x, msg, N)"}
    ]

    test "a module under the AshA2A.ConsequenceKernel prefix is not exempt from any DO entry" do
      for {name, body} <- @do_bodies do
        m = mutant_named(Module.concat(AshA2A.ConsequenceKernel, "Evil" <> name), body)
        report = ClosureCourt.report(modules: @core, extra_modules: [m])
        assert report.verdict == "violations", name
        assert Enum.any?(report.violating_edges, &(&1[:caller] == "#{inspect(m)}.go/1")), name
      end
    end

    test "the pinned gateway alone is still the kernel's only Dispatcher caller" do
      report = ClosureCourt.report(modules: @core)
      assert report.violating_edges == []
      assert report.kernel_gateways == ["AshA2A.ConsequenceKernel.W4.DispatchInversion.execute/2"]
    end

    test "a non-resource module under a fixture prefix cannot perform an Ash effect" do
      for prefix <- [
            AshA2A.Chicago.Fixtures,
            AshA2A.Test.Fixture,
            AshA2A.ArchitectureVerifier.Fixture
          ] do
        m = mutant_named(Module.concat(prefix, "EvilD"), "Ash.create(msg)")
        report = ClosureCourt.report(modules: @core, extra_modules: [m])
        assert report.verdict == "violations", inspect(prefix)
        assert Enum.any?(report.violating_edges, &(&1[:caller] == "#{inspect(m)}.go/1"))
      end
    end

    test "a dynamic call to a DO entry from any module is a violation" do
      for {name, body} <- [
            {"DynDispatch",
             ~s|(fn m -> m.dispatch(:x, msg, N) end).(Module.concat(["AshA2A", "Dispatcher"]))|},
            {"DynExecute", ~s|(fn m -> m.execute(msg, msg, msg, msg, msg) end).(msg)|},
            {"DynApply", ~s|apply(msg, :whatever, [msg])|}
          ] do
        m = mutant_named(Module.concat(AshA2A.Evil, name), body)
        report = ClosureCourt.report(modules: @core, extra_modules: [m])
        assert report.verdict == "violations", name

        assert Enum.any?(
                 report.violating_edges,
                 &(&1[:caller] == "#{inspect(m)}.go/1" and
                     &1.violation == "unlisted_dynamic_site_in_do_adjacent_module")
               ),
               name
      end
    end

    test "a dynamic call with a non-DO function name from an unrelated module is not flagged" do
      m =
        mutant_named(Module.concat(AshA2A.Evil, "DynBenign"), "(fn m -> m.render(msg) end).(msg)")

      report = ClosureCourt.report(modules: @core, extra_modules: [m])
      assert report.verdict == "closed"
    end
  end

  describe "legacy observe path stays fenced" do
    test "dispatch_observe refuses a consequence-bearing skill and performs no effect" do
      label = "c1-observe-#{System.unique_integer([:positive])}"

      msg = A2A.Message.new_user([A2A.Part.Data.new(%{"label" => label})])

      assert {:error, _} = AshA2A.Dispatcher.dispatch_observe(:record, msg, Ledger)
      refute label in AshA2A.Chicago.Fixtures.Brce.ledger_labels()
    end
  end
end
