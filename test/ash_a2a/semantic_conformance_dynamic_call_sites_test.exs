defmodule AshA2A.SemanticConformanceDynamicCallSitesTest do
  @moduledoc """
  Regression cover for `check_no_llm_on_production_do_path/0` returning a
  vacuously-true `:met`.

  The defect: `collect_remote_modules/1` matched only
  `{:call, _, {:remote, _, {:atom, _, module}, _}, _}`, so a call whose
  module is a variable, or an `apply/3` whose module argument is computed,
  contributed no target at all. The check then concluded "none is an LLM
  module" from the targets it *could* see.

  A real scan of the real compiled DO-path beams found this is not
  hypothetical -- `AshA2A.CommandBus` carries variable-module call sites and
  `AshA2A.ReceiptOutbox` carries an `:erlang.apply/3` site -- and the check
  nonetheless returned:

      {:met, "scanned the real BEAM abstract code of 5 DO-path module(s)
       (...) covering 75 distinct remote-call target(s); none is an LLM
       module"}

  Everything below reads real abstract code out of real `.beam` files through
  the real `:beam_lib`, exactly as the production check does.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Semantic.Conformance
  alias AshA2A.Test.{DynamicCallSiteFixture, StaticCallSiteFixture}

  describe "the blind spot is real and is now detected" do
    test "remote_call_targets/1 still sees only the literally named callee" do
      assert {:ok, targets} = Conformance.remote_call_targets(DynamicCallSiteFixture)

      # The literal call is visible ...
      assert AshA2A.Providers.NeverCalled in targets

      # ... and the three dynamic ones name nothing at all, which is the
      # blind spot. This assertion documents it rather than hiding it.
      assert {:ok, sites} = Conformance.dynamic_call_sites(DynamicCallSiteFixture)
      assert length(sites) >= 3
    end

    test "dynamic_call_sites/1 finds all three dynamic shapes" do
      assert {:ok, sites} = Conformance.dynamic_call_sites(DynamicCallSiteFixture)
      kinds = sites |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()

      assert :variable_module in kinds
      assert :dynamic_apply in kinds
      assert :dynamic_make_fun in kinds
    end

    test "it reports nothing for a module whose every callee is an atom literal" do
      assert {:ok, []} = Conformance.dynamic_call_sites(StaticCallSiteFixture)
    end

    test "every site carries a real source line" do
      assert {:ok, sites} = Conformance.dynamic_call_sites(DynamicCallSiteFixture)

      for {_kind, line} <- sites do
        assert is_integer(line) and line > 0
      end
    end

    test "unavailable abstract code is still an error, never a guess" do
      assert {:error, _} = Conformance.dynamic_call_sites(:erlang)
      assert {:error, _} = Conformance.remote_call_targets(NoSuchModuleAnywhere)
    end
  end

  describe "the production DO path really carries dynamic call sites" do
    test "CommandBus dispatches on a runtime module value" do
      assert {:ok, sites} = Conformance.dynamic_call_sites(AshA2A.CommandBus)
      assert sites != [], "expected the reproduced variable-module sites in CommandBus"
    end

    test "ReceiptOutbox carries an erlang:apply/3 site" do
      assert {:ok, sites} = Conformance.dynamic_call_sites(AshA2A.ReceiptOutbox)
      assert sites != []
    end
  end

  describe "the requirement is now :unverifiable, not a false :met" do
    test "check_no_llm_on_production_do_path/0 reports unverifiable and says why" do
      assert {:unverifiable, detail} = Conformance.check_no_llm_on_production_do_path()

      assert detail =~ "runtime value"
      assert detail =~ "AshA2A.CommandBus"
      assert detail =~ "not decidable by AST inspection"
    end

    test "it would still be :unmet, not :unverifiable, if a literal LLM target appeared" do
      # The dynamic-site branch must not swallow a real violation. The
      # fixture module carries a literal AshA2A.Providers.* call AND dynamic
      # sites; `llm_module?/1` classifies that literal target, and the
      # ordering in the check puts :unmet ahead of :unverifiable.
      assert {:ok, targets} = Conformance.remote_call_targets(DynamicCallSiteFixture)
      assert Enum.any?(targets, &Conformance.llm_module?/1)
    end
  end

  describe "the roll-up counts are corrected, and the earned level stays honest" do
    @tag timeout: 300_000
    test "the DO-path requirement is counted as unverifiable and earned_level stays :none" do
      results = Conformance.requirement_results()
      grouped = Enum.group_by(results, & &1.status)

      assert length(results) == 34

      # Before the fix: met 15, unmet 19, unverifiable 0. The DO-path
      # requirement moves out of :met and into :unverifiable.
      assert length(Map.get(grouped, :met, [])) == 14
      assert length(Map.get(grouped, :unmet, [])) == 19
      assert length(Map.get(grouped, :unverifiable, [])) == 1

      unverifiable = Map.get(grouped, :unverifiable, [])
      assert Enum.any?(unverifiable, &(&1.detail =~ "not decidable by AST inspection"))

      # An :unverifiable requirement blocks conformance exactly as hard as an
      # :unmet one, so nothing here buys a level.
      assert Conformance.earned_level(results) == :none
    end
  end
end
