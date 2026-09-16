defmodule Mix.Tasks.AshA2a.Chicago do
  @shortdoc "Runs the RFC-SA2A-002 Chicago conformance court"

  @moduledoc """
  Runs the RFC-SA2A-002 v26.9.16 Chicago conformance court against this exact
  checkout and writes the conformance package (§114).

      mix ash_a2a.chicago --profile strict --evidence-dir tmp/chicago
      mix ash_a2a.chicago --profile do --court CHI-BRCE --court CHI-POST
      mix ash_a2a.chicago --list

  Options:

    * `--profile` -- `core | logic | plan | do | strict` (default `core`)
    * `--evidence-dir` -- package output directory (default: fresh tmp dir)
    * `--court` -- restrict to a court id (repeatable)
    * `--list` -- list discoverable courts and exit
    * `--require-conformant` -- exit non-zero unless standing is CONFORMANT

  Package files: `ocel.json`, `ocel_validation.json`, `results.json`,
  `subject.json`, `standing_receipt.json`.

  Courts that need test-only fixtures run under `MIX_ENV=test`.
  """

  use Mix.Task

  alias AshA2A.Chicago
  alias AshA2A.Chicago.Profile

  @switches [
    profile: :string,
    evidence_dir: :string,
    court: :keep,
    list: :boolean,
    require_conformant: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, invalid} = OptionParser.parse(argv, strict: @switches)
    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    Mix.Task.run("app.start")

    if opts[:list] do
      for court <- Chicago.courts() do
        Mix.shell().info(
          "#{court.id()}\tgate=#{court.gate() || "-"}\t#{Profile.name(court.profile())}\t#{length(court.falsifiers())} falsifiers\t#{court.title()}"
        )
      end
    else
      execute(opts)
    end
  end

  defp execute(opts) do
    profile =
      case Profile.parse(Keyword.get(opts, :profile, "core")) do
        {:ok, profile} -> profile
        {:error, _} -> Mix.raise("unknown profile #{inspect(opts[:profile])}")
      end

    run_opts =
      [profile: profile]
      |> put_if(:evidence_dir, opts[:evidence_dir] && Path.expand(opts[:evidence_dir]))
      |> put_if(:court_ids, empty_to_nil(Keyword.get_values(opts, :court)))

    case Chicago.run(run_opts) do
      {:ok, run} ->
        receipt = run.receipt
        Mix.shell().info(receipt["claim"])
        Mix.shell().info("standing: #{receipt["standing"]}")
        Mix.shell().info("results: #{inspect(receipt["results"], limit: :infinity)}")
        Mix.shell().info("evidence: #{run.evidence_dir}")

        if opts[:require_conformant] && receipt["standing"] != "CONFORMANT" do
          Mix.raise("standing #{receipt["standing"]} is not CONFORMANT")
        end

      {:error, reason} ->
        Mix.raise("chicago run failed: #{inspect(reason)}")
    end
  end

  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, key, value), do: Keyword.put(opts, key, value)

  defp empty_to_nil([]), do: nil
  defp empty_to_nil(list), do: list
end
