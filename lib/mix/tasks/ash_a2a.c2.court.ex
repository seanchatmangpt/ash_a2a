defmodule Mix.Tasks.AshA2a.C2.Court do
  @shortdoc "Runs the RFC-SA2A-006 s26 C2 compromise court against the real authority_service and actuator"

  @moduledoc """
  Runs the C2 compromise court (`test/ash_a2a/c2_compromise/`) and prints where the JSON
  report went and its overall verdict.

      mix ash_a2a.c2.court
      mix ash_a2a.c2.court --n 50 --report tmp/c2_court/full.json
      mix ash_a2a.c2.court --only C2C-A11,C2C-F02 --no-mutation

  The court starts three real OS processes (a keymaster holding every key, the
  `actuator/` project, the `authority_service/` project) with separate build roots and state
  directories and no Erlang distribution, plays an attacker that controls the control-plane
  node from inside the test VM, and judges every attack from the actuator's hash-chained effect
  ledger. Hosting scope: separate-process, same-host, same OS uid. See
  `docs/reference/c2-compromise-court.md`.

  ## Options

    * `--n` -- repetitions of each fault-injection attack (default 20, at most 50)
    * `--mutant-n` -- repetitions inside mutant fleets (default 3)
    * `--report` -- report path (default `tmp/c2_court/report.json`)
    * `--build-root` -- directory for the child projects' own `MIX_BUILD_ROOT`s
      (default `<tmp>/c2-court-build`)
    * `--only` -- comma-separated attack ids
    * `--no-mutation` -- skip the mutation court (a run without it is never reported PASS
      by the test that requires it)

  The court needs no database. It is tagged `:c2_court` (and `:serial`, `:serial_solo`), so
  `mix test` excludes it and `mix test.all` includes it; this task is the direct entry point
  and exits non-zero when any court assertion fails.
  """
  use Mix.Task

  @max_n 50

  @impl Mix.Task
  def run(args) do
    {opts, _rest, invalid} =
      OptionParser.parse(args,
        strict: [
          n: :integer,
          mutant_n: :integer,
          report: :string,
          build_root: :string,
          only: :string,
          no_mutation: :boolean
        ]
      )

    if invalid != [], do: Mix.raise("unknown options: #{inspect(invalid)}")

    n = opts |> Keyword.get(:n, 20) |> max(1) |> min(@max_n)
    report = Path.expand(Keyword.get(opts, :report, "tmp/c2_court/report.json"))

    env =
      [
        {"MIX_ENV", "test"},
        {"C2_COURT_N", Integer.to_string(n)},
        {"C2_COURT_MUTANT_N", Integer.to_string(Keyword.get(opts, :mutant_n, 3))},
        {"C2_COURT_REPORT", report},
        {"C2_COURT_MUTATION", if(opts[:no_mutation], do: "0", else: "1")}
      ] ++
        if(opts[:only], do: [{"C2_COURT_ONLY", opts[:only]}], else: []) ++
        if(opts[:build_root],
          do: [{"C2_COURT_BUILD_ROOT", Path.expand(opts[:build_root])}],
          else: []
        )

    mix = System.find_executable("mix") || Mix.raise("mix is not on PATH")

    {_, status} =
      System.cmd(
        mix,
        ["test", "--only", "c2_court", "test/ash_a2a/c2_compromise/c2_compromise_court_test.exs"],
        env: env,
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true
      )

    summarize(report)
    if status != 0, do: Mix.raise("C2 compromise court failed (exit #{status})")
    :ok
  end

  defp summarize(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"summary" => s, "commit_sha" => sha}} <- Jason.decode(body) do
      Mix.shell().info(
        "C2 court @ #{sha}: overall=#{s["overall"]} attacks=#{s["attacks"]} verdicts=#{inspect(s["verdicts"])}"
      )

      Mix.shell().info("report: #{path}")
    else
      _ -> Mix.shell().error("no report at #{path}")
    end
  end
end
