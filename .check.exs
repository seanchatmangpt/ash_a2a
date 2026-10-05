# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT
#
# One-command quality gate for ash_a2a, modeled on the ash-project PR bar
# (compile, tests, spark.formatter --check, Credo --strict, Dialyzer, docs
# generation, Sobelow) plus this repo's own v1.0 conformance gate.
#
# Run:   mix check
# Scope: CHECK_STAGES=compile,test mix check     (comma-separated subset)
# List:  CHECK_STAGES=list mix check             (print stages and exit)
#
# Full target set (the ash-project bar, in gate order):
#
#   compile         mix compile --warnings-as-errors
#   test            mix test  THEN  mix test.serial (fast lane plus the
#                    serial tail as an explicit serial sub-stage: a green
#                    staged run must not hide serial-shard failures)
#   spark_formatter mix spark.formatter --check
#   conformance     ash_a2a.v1_conformance_report, gated on
#                    totals.fail == 0 (the report task itself always
#                    exits 0; the gate is the JSON)
#   docs            mix docs
#   credo           mix credo --strict              (config: .credo.exs)
#   dialyzer        mix dialyzer                    (LONG: a cold-PLT build
#                    can take tens of minutes; long-timeout by design)
#   sobelow         mix sobelow --exit high         (transports are the
#                    attack surface: a2a_transport/{plug,sse,
#                    push_config_rpc}.ex and transport/grpc/*)
#
# Honest staging, measured 2026-10-04 on this tree (blockers named, not
# hidden -- all stages stay wired; promote into `default_stages` the moment
# a stage is green on main):
#
#   compile         GREEN
#   test            RED  -- fast lane carries 2 failures owned by OTHER
#                    lanes (stale PolicyPhenotype bench receipt; unmapped
#                    :unsupported refusal code, test/ash_a2a/semantic_refusal_test.exs
#                    scans lib/); both pass in isolation once their owners
#                    land. Serial tail now runs as an explicit sub-stage
#                    (X16: closing the `:serial`-inclusion blind spot -- a
#                    green staged run must not be able to hide serial-shard
#                    failures).
#   spark_formatter RED  -- `mix spark.formatter --check` raises without
#                    import_deps in .formatter.exs (ownership: formatter config)
#   conformance     WIRED, not yet run to completion here (tens of minutes;
#                    gate = totals.fail == 0 on the JSON report)
#   docs            RED  -- ExDoc.Extras.build/2 raises on the current extras
#                    list (mix.exs docs/0); ownership: mix.exs docs config
#   credo           RED  -- first strict run: 288 findings (1 consistency,
#                    18 warnings, 55 refactoring, 214 readability); trimming
#                    further or fixing findings is follow-up work
#   dialyzer        WIRED, long-running (cold-PLT build: tens of minutes)
#   sobelow         GREEN (`--exit high` -- no high-confidence findings)
#
# Default set is therefore the minimal verified subset `compile,test` --
# the contract falsifier is CHECK_STAGES=compile,test mix check.

stages =
  [
    # {name, [[command, args...], ...]} -- a stage runs ONE OR MORE
    # sub-commands as real OS subprocesses with streamed output, in order,
    # fail-fast within the stage; pass = every sub-command exits 0.
    # MIX_ENV per stage: `test` (and only `test`) runs in MIX_ENV=test --
    # config/test.exs sets keys the suite refuses without (e.g.
    # :chicago_topology_root); analysis stages run in the default :dev.
    {:compile, [["mix", "compile", "--warnings-as-errors"]]},

    # X16 fix: the staged test stage previously ran ONLY the fast lane
    # (`mix test`, whose alias excludes :serial), so a green staged run
    # could hide serial-shard failures (X9-era adversarial probe). The
    # serial tail now runs as an explicit second sub-stage via the
    # `test.serial` alias (`--only serial` -- covers both :serial_solo and
    # :serial_shard files, i.e. the full excluded tail). Stage stays
    # fail-fast: a serial sub-stage failure fails the :test stage.
    {:test, [["mix", "test"], ["mix", "test.serial"]]},

    {:spark_formatter, [["mix", "spark.formatter", "--check"]]},
    {:conformance,
     [
       [
         "mix",
         "run",
         "-e",
         """
         alias Mix.Tasks.AshA2a.V1ConformanceReport
         out = Path.join("tmp", "v1_conformance_check.json")
         File.mkdir_p!("tmp")
         V1ConformanceReport.run(["--out", out])
         totals = out |> File.read!() |> JSON.decode!() |> Map.fetch!("totals")
         fail = Map.get(totals, "fail")
         IO.puts("[conformance] totals.fail = " <> to_string(fail))
         if fail in [nil, 0], do: IO.puts("[conformance] GATE PASS"), else: exit({:shutdown, 1})
         """
       ]
     ]},
    {:docs, [["mix", "docs"]]},
    {:credo, [["mix", "credo", "--strict"]]},
    {:dialyzer, [["mix", "dialyzer"]]},
    {:sobelow, [["mix", "sobelow", "--exit", "high"]]}
  ]

default_stages = ~w(compile test)a

named = Enum.into(stages, %{}, fn {name, cmd} -> {name, cmd} end)
full = Keyword.keys(stages)

requested =
  System.get_env("CHECK_STAGES", "")
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.map(&String.downcase/1)
  |> Enum.map(&String.to_atom/1)
  |> case do
    [] -> default_stages
    atoms -> atoms
  end

if requested == ~w(list)a do
  IO.puts("Stages (full set): #{Enum.join(full, ", ")}")
  IO.puts("Default set:       #{Enum.join(default_stages, ", ")}")
  System.halt(0)
end

unknown = requested -- full

if unknown != [] do
  IO.puts(:standard_error, "CHECK_STAGES: unknown stage(s): #{Enum.join(unknown, ", ")}")
  IO.puts(:standard_error, "Known stages: #{Enum.join(full, ", ")}")
  System.halt(64)
end

IO.puts("== mix check (stages: #{Enum.join(requested, ", ")}) ==")

{results, failed?} =
  Enum.reduce(requested, {[], false}, fn stage, {acc, failed?} ->
    if failed? do
      {acc, failed?}
    else
      cmds = Map.fetch!(named, stage)
      total = length(cmds)
      stage_env = %{"MIX_ENV" => if(stage == :test, do: "test", else: "dev")}

      {stage_outcome, _} =
        Enum.reduce_while(cmds, {nil, nil}, fn cmd, {_, _} ->
          label =
            if total == 1 do
              "STAGE #{stage}"
            else
              "STAGE #{stage} (#{Enum.find_index(cmds, &(&1 == cmd)) + 1}/#{total})"
            end

          IO.puts("\n==> #{label}: mix #{Enum.join(cmd |> tl(), " ")}")

          case System.cmd(hd(cmd), tl(cmd), env: stage_env, into: IO.stream()) do
            {_, 0} ->
              {:cont, {nil, nil}}

            {_, code} -> {:halt, {{:fail, code}, nil}}
          end
        end)

      case stage_outcome do
        nil ->
          IO.puts("==> STAGE #{stage}: PASS")
          {[{stage, :pass} | acc], failed?}

        {:fail, code} ->
          IO.puts("==> STAGE #{stage}: FAIL (exit #{code})")
          {[{stage, {:fail, code}} | acc], true}
      end
    end
  end)

results = Enum.reverse(results)

IO.puts("\n== mix check summary ==")

Enum.each(results, fn
  {stage, :pass} -> IO.puts("  PASS  #{stage}")
  {stage, {:fail, code}} -> IO.puts("  FAIL  #{stage} (exit #{code})")
end)

if failed? do
  skipped = full -- (requested -- Enum.map(results, fn {s, _} -> s end))

  if skipped != [] do
    IO.puts("  SKIPPED (halted after first failure): #{Enum.join(skipped, ", ")}")
  end
end

if failed?, do: System.halt(1), else: IO.puts("\nAll configured stages green.")
