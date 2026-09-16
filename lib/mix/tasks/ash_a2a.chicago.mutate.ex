defmodule Mix.Tasks.AshA2a.Chicago.Mutate do
  @shortdoc "Runs the RFC-SA2A-002 §22/§97 anti-vacuity mutation catalog"

  @moduledoc """
  Hot-loads each `AshA2A.Chicago.Mutation.Catalog` mutant into this exact
  checkout, runs the courts expected to kill it, restores the original BEAM
  and reports `mutant_killed | mutant_survived | blocked | unknown`.

      mix ash_a2a.chicago.mutate
      mix ash_a2a.chicago.mutate --only authority_check_true --only ignore_expiry
      mix ash_a2a.chicago.mutate --list
      mix ash_a2a.chicago.mutate --evidence-dir tmp/mutations --require-killed

  Options:

    * `--only` -- restrict to a catalog id (repeatable)
    * `--evidence-dir` -- where each baseline/mutant conformance package and
      `mutation_report.json` are written (default: fresh tmp dir)
    * `--list` -- resolve every entry (target + killer courts) without loading anything
    * `--require-killed` -- exit non-zero unless every selected mutant is killed

  A `mutant_survived` line names a court that is vacuous for that guard
  (§11: a falsifier that passes with its guard deleted is presumed vacuous).
  """

  use Mix.Task

  alias AshA2A.Chicago.{Json, Mutation}
  alias AshA2A.Chicago.Mutation.{Catalog, Verdict}

  @switches [only: :keep, evidence_dir: :string, list: :boolean, require_killed: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, invalid} = OptionParser.parse(argv, strict: @switches)
    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    # The reference court drives the real CommandBus, which reconciles any
    # receipt-outbox journal it finds. Unless one is configured, give this run
    # its own journal so it never drains another process's pending receipts.
    unless Application.get_env(:ash_a2a, :receipt_outbox_dir) do
      Application.put_env(
        :ash_a2a,
        :receipt_outbox_dir,
        Path.join(
          System.tmp_dir!(),
          "ash_a2a-mutate-outbox-#{System.unique_integer([:positive])}"
        )
      )
    end

    Mix.Task.run("app.start")

    only = Keyword.get_values(opts, :only)
    unknown = only -- Catalog.ids()

    if unknown != [],
      do: Mix.raise("unknown mutation ids #{inspect(unknown)}; known: #{inspect(Catalog.ids())}")

    if opts[:list], do: list(only), else: execute(only, opts)
  end

  defp selected(only), do: Enum.filter(Catalog.entries(), &(only == [] or &1.id in only))

  defp list(only) do
    for entry <- Catalog.resolution(), only == [] or entry.id in only do
      target =
        case entry.target_status do
          %{status: :resolvable} -> "resolvable"
          %{status: :blocked, code: code} -> "BLOCKED #{code}"
        end

      Mix.shell().info(
        "#{entry.id}\t#{entry.target}\t#{target}\tkillers=#{Enum.join(entry.killers.resolved, ",")}" <>
          "\tmissing=#{Enum.join(entry.killers.missing, ",")}"
      )
    end
  end

  defp execute(only, opts) do
    root =
      case opts[:evidence_dir] do
        nil ->
          Path.join(System.tmp_dir!(), "ash_a2a-mutate-#{System.unique_integer([:positive])}")

        dir ->
          Path.expand(dir)
      end

    {verdicts, _cache} =
      Enum.map_reduce(selected(only), %{}, fn m, cache ->
        {baseline_opts, cache} =
          with {:ok, courts, _} <- Mutation.killer_courts(m),
               {:ok, _plan} <- Mutation.prepare(m) do
            {baseline, cache} = Mutation.cached_baseline(courts, root, cache)
            {[baseline: baseline], cache}
          else
            _ -> {[], cache}
          end

        v = Mutation.qualify(m, [evidence_dir: Path.join(root, m.id)] ++ baseline_opts)

        Mix.shell().info(
          "#{String.upcase(to_string(v.verdict))}\t#{v.mutation_id}\t#{v.target}\t" <>
            "courts=#{inspect(v.court_verdicts)}\tcalls=#{inspect(v.mutant_calls)}\t#{v.detail}"
        )

        {v, cache}
      end)

    File.mkdir_p!(root)
    report = Path.join(root, "mutation_report.json")
    File.write!(report, Json.canonical(Enum.map(verdicts, &Verdict.to_map/1)))

    tally = Enum.frequencies_by(verdicts, & &1.verdict)
    Mix.shell().info("tally: #{inspect(tally)}")
    Mix.shell().info("report: #{report}")

    unpristine =
      selected(only)
      |> Enum.map(& &1.module)
      |> Enum.uniq()
      |> Enum.filter(&Code.ensure_loaded?/1)
      |> Enum.reject(&Mutation.pristine?/1)

    if unpristine != [], do: Mix.raise("modules left mutated: #{inspect(unpristine)}")

    if opts[:require_killed] && Enum.any?(verdicts, &(&1.verdict != :mutant_killed)) do
      Mix.raise("not every selected mutant was killed: #{inspect(tally)}")
    end
  end
end
