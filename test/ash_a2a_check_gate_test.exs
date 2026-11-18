defmodule AshA2A.CheckGateTest do
  @moduledoc """
  Gate for the gate: asserts `mix check` (`.check.exs`) is fully wired --
  every ash-project-bar stage declared, the default subset green-scoped,
  the alias and dev deps present, and the script itself executable (real
  `CHECK_STAGES=list` subprocess).
  """

  use ExUnit.Case, async: true

  @check_script Path.join(__DIR__, "../.check.exs") |> Path.expand()
  @credo_config Path.join(__DIR__, "../.credo.exs") |> Path.expand()
  @mix_exs Path.join(__DIR__, "../mix.exs") |> Path.expand()

  @full_stages ~w(compile test spark_formatter conformance docs credo dialyzer sobelow)
  @default_stages ~w(compile test)

  describe "check script stage wiring" do
    test "declares every stage of the ash-project bar" do
      script = File.read!(@check_script)

      for stage <- @full_stages do
        assert script =~ "{:#{stage}", message: "stage #{stage} not declared in .check.exs"
      end
    end

    test "every declared command names a real mix task or compile/test/docs entrypoint" do
      script = File.read!(@check_script)

      # conformance stage must gate on the real report task that exists on disk
      assert File.exists?(Path.join(__DIR__, "../lib/mix/tasks/ash_a2a.v1_conformance_report.ex"))

      assert script =~ "ash_a2a.v1_conformance_report" or script =~ "V1ConformanceReport"
      assert script =~ "--warnings-as-errors"
      assert script =~ "spark.formatter"
      assert script =~ "--strict"
      assert script =~ "dialyzer"
      assert script =~ "sobelow"
    end

    test "CHECK_STAGES scoping is implemented" do
      script = File.read!(@check_script)
      assert script =~ "CHECK_STAGES"
    end

    test "default set is a subset of the full set" do
      script = File.read!(@check_script)

      default_decl =
        script |> String.split("default_stages = ") |> Enum.at(1) |> String.split("\n") |> hd

      for stage <- @default_stages do
        assert default_decl =~ stage, "default stage #{stage} missing from @default_stages decl"
      end
    end

    test "script compiles and runs: CHECK_STAGES=list exits 0 and lists the full set" do
      {out, code} =
        System.cmd("mix", ["check"],
          env: %{"CHECK_STAGES" => "list", "MIX_BUILD_ROOT" => build_root()},
          stderr_to_stdout: true,
          cd: Path.join(__DIR__, "..")
        )

      assert code == 0, out

      for stage <- @full_stages do
        assert out =~ stage
      end

      assert out =~ "Default set"
    end

    test "unknown stage is refused with exit 64" do
      {out, code} =
        System.cmd("mix", ["check"],
          env: %{"CHECK_STAGES" => "compile,bogus_stage", "MIX_BUILD_ROOT" => build_root()},
          stderr_to_stdout: true,
          cd: Path.join(__DIR__, "..")
        )

      assert code == 64, out
      assert out =~ "unknown stage"
    end
  end

  describe "mix.exs wiring" do
    test "check alias dispatches to the check script" do
      assert File.read!(@mix_exs) =~ ~s(check: "run .check.exs")
    end

    test "credo and sobelow are declared dev deps" do
      mix = File.read!(@mix_exs)
      assert mix =~ ~s({:credo, "~> 1.7", only: :dev, runtime: false})
      assert mix =~ ~s({:sobelow, "~> 0.13", only: :dev, runtime: false})
    end
  end

  describe "credo config" do
    test "parses as Elixir and is strict with lib on the analysis path" do
      assert {config, _} = Code.eval_string(File.read!(@credo_config))
      assert %{configs: [cfg]} = config
      assert cfg.strict == true
      assert "lib/" in cfg.files.included
    end
  end

  defp build_root do
    System.get_env("MIX_BUILD_ROOT") || "_build"
  end
end
