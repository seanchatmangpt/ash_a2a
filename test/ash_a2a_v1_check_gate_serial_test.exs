# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.V1.CheckGateSerialTest do
  @moduledoc """
  X16 lane court: closes the `:serial`-inclusion blind spot in the staged
  check gate (X9-era finding).

  The gate-for-the-gate (`test/ash_a2a_check_gate_test.exs`) asserted stage
  WIRING but never asserted that the gate's `:test` stage actually covers
  the serial tail -- so the staged run could go green while every
  `:serial`-tagged test (the ~96-file `mix test.serial` shard+solo tail) was
  silently excluded (`mix test` == `test --exclude serial`, mix.exs alias).

  Three layers, all real:

  1. Structural: the `:test` stage spec in `.check.exs` must declare a
     serial-including sub-command (the `test.serial` alias), not only the
     fast lane.
  2. Fixed-direction witness (real `mix run` subprocess over a scratch mix
     project): with a failing `:serial`-tagged test present, the gate's
     `:test` stage must FAIL, and the output must show the serial sub-stage
     actually dispatching (`2/2: mix test.serial`).
  3. Anti-vacuity mutation witness: with the fix reverted in the scratch
     copy of the script (fast lane only), the same failing serial test is
     NOT observed -- the stage goes green anyway. Reverting the fix must
     reproduce the blind spot, or the court asserts nothing.

  No shared-suite pollution: the scratch project (and its `_build`) is
  unique per run and deleted in `on_exit`.
  """

  use ExUnit.Case, async: true

  @check_script Path.join(__DIR__, "../.check.exs") |> Path.expand()

  @fixed_spec ~s({:test, [["mix", "test"], ["mix", "test.serial"]]},)

  describe "check gate serial inclusion (X16)" do
    test "structural: the :test stage declares the fast lane AND a serial-including sub-stage" do
      script = File.read!(@check_script)

      # The exact stage spec must carry both sub-commands...
      assert script =~ @fixed_spec,
             "the :test stage must run `mix test` then `mix test.serial`"

      # ...and the serial sub-command must be the `test.serial` alias, the
      # one positive selector for the excluded tail.
      test_stage_spec =
        script |> String.split("{:test,") |> Enum.at(1) |> String.split("]},") |> hd

      assert test_stage_spec =~ ~s("test.serial"),
             "serial sub-stage must dispatch the test.serial alias (--only serial)"
    end

    test "fixed direction: a failing :serial-tagged test FAILS the staged :test stage" do
      assert {out, code} = run_gate_in_scratch(mutation: false)

      assert code != 0, "stage must fail -- log:\n#{out}"

      # The serial sub-stage must actually have dispatched...
      assert out =~ "2/2): mix test.serial"

      # ...the summary must fail the :test stage...
      assert out =~ "  FAIL  test"

      # ...and the failing serial test must be visible in its output.
      assert out =~ "scratch_serial_test.exs"
      assert out =~ "1 failure"
    end

    @tag :regression
    test "anti-vacuity: reverting the fix re-hides the failing serial test (stage goes green)" do
      assert {out, code} = run_gate_in_scratch(mutation: true)

      # Blind spot reproduced: fast lane passes, serial tail never runs.
      assert code == 0, "mutated script must NOT see the serial failure -- log:\n#{out}"
      assert out =~ "  PASS  test"
      refute out =~ "scratch_serial_test.exs"
      refute out =~ "test.serial"
    end
  end

  ## Scratch harness: a real minimal mix project with the repo's alias
  ## shape (fast lane excludes :serial; `test.serial` re-selects it), a
  ## passing fast test, a DELIBERATELY FAILING :serial-tagged test, and a
  ## copy of the canonical gate script. `CHECK_STAGES=test mix run
  ## .check.exs` then runs the gate's real code path against it.

  @scratch_mix """
  defmodule CheckGateScratch.MixProject do
    use Mix.Project

    def project do
      [
        app: :check_gate_scratch,
        version: "0.1.0",
        aliases: [
          test: "test --exclude serial",
          "test.serial": "test --only serial"
        ]
      ]
    end
  end
  """

  @scratch_helper "ExUnit.start()\n"

  @scratch_fast_test """
  defmodule ScratchFastTest do
    use ExUnit.Case, async: true

    test "fast lane is green" do
      assert 1 + 1 == 2
    end
  end
  """

  @scratch_serial_test """
  defmodule ScratchSerialTest do
    use ExUnit.Case, async: false

    @tag :serial
    test "deliberately failing serial-shard test (X16 fixture)" do
      # Deliberately false, and type-homogeneous so the fixture contributes
      # zero compiler warnings (they would pollute the gate-log evidence).
      assert String.upcase("x16") == "SERIAL_SHARD_WAS_OBSERVED"
    end
  end
  """

  defp run_gate_in_scratch(opts) do
    mutation? = Keyword.fetch!(opts, :mutation)
    token = System.unique_integer([:positive])
    scratch = Path.join(System.tmp_dir!(), "x16_check_gate_scratch_#{token}")
    File.mkdir_p!(Path.join(scratch, "test"))

    fixed_script = File.read!(@check_script)

    # The mutation is the X9-era pre-fix spec: fast lane ONLY.
    mutated_script =
      String.replace(fixed_script, @fixed_spec, ~s({:test, [["mix", "test"]]},))

    script_text = if mutation?, do: mutated_script, else: fixed_script

    if mutation? do
      # The mutation must actually strip the serial sub-stage spec, or the
      # witness below is vacuous in the other direction. (Header-comment
      # mentions of `test.serial` may remain -- the behavior is what must
      # differ.)
      refute script_text =~ @fixed_spec
    end

    File.write!(Path.join(scratch, "mix.exs"), @scratch_mix)
    File.write!(Path.join([scratch, "test", "test_helper.exs"]), @scratch_helper)
    File.write!(Path.join([scratch, "test", "scratch_fast_test.exs"]), @scratch_fast_test)
    File.write!(Path.join([scratch, "test", "scratch_serial_test.exs"]), @scratch_serial_test)
    File.write!(Path.join(scratch, ".check.exs"), script_text)

    build_root = Path.join(scratch, "_build_x16")
    File.mkdir_p!(build_root)

    {out, code} =
      System.cmd("mix", ["run", ".check.exs"],
        env: %{
          "CHECK_STAGES" => "test",
          "MIX_BUILD_ROOT" => build_root,
          "MIX_ENV" => "dev"
        },
        stderr_to_stdout: true,
        cd: scratch
      )

    on_exit(fn -> File.rm_rf!(scratch) end)

    {out, code}
  end
end
