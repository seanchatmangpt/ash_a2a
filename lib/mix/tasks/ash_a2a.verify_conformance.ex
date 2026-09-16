# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshA2a.VerifyConformance do
  @shortdoc "Runs the real RFC-SA2A-001 conformance profile checks (CI gate)"

  @moduledoc """
  Machine-checkable RFC-SA2A-001 v26.9.16 conformance verifier for `ash_a2a`.

  Mirrors `mix ash_a2a.verify_architecture` (`AshA2A.ArchitectureVerifier`):
  every line printed below is the result of a REAL executable check that ran
  against this repo's own real compiled code -- not documentation of an
  intended requirement someone forgot to update.

      mix ash_a2a.verify_conformance
      mix ash_a2a.verify_conformance --claim sa2a-core
      mix ash_a2a.verify_conformance --claim SA2A-DO --verbose

  ## What it prints

    1. One `MET` / `UNMET` / `UNVERIFIABLE` line per RFC S59 profile
       requirement, grouped by the profile level that introduces it.
    2. A per-level cumulative roll-up (`SA2A-CORE` ... `SA2A-STRICT`), where a
       level is conformant only if its FULL cumulative requirement set is met.
    3. One `HOLDS` / `VIOLATED` / `UNVERIFIABLE` line per RFC S60 invariant,
       each carrying the scope (`witnessed` / `structural` / `none`) that says
       how strongly it was established.
    4. The honestly-earned level -- `none` when even SA2A-CORE is not fully
       met.

  ## Exit status

  With no `--claim`, this task is a REPORT: it always exits 0, because "here is
  what is and is not met today" is not a failure.

  With `--claim <level>`, it is a GATE: it exits non-zero (via `Mix.raise/1`)
  if any requirement in that level's cumulative set is `UNMET` or
  `UNVERIFIABLE`, or if any RFC S60 invariant is `VIOLATED`. An unverifiable
  requirement fails a claim exactly as hard as an unmet one -- see
  `AshA2A.Semantic.Profile`'s moduledoc for why counting unverifiable
  requirements as satisfied would corrupt the conformance story.

  ## Options

    * `--claim LEVEL` -- assert conformance at LEVEL and fail if it is not
      really earned. Accepts `sa2a-core`/`SA2A-CORE`/`sa2a_core` spellings.
    * `--verbose` -- also print the full detail line for `MET` requirements
      and `HOLDS` invariants (details for unmet/violated/unverifiable ones are
      always printed, because those are the load-bearing ones).
    * `--explain` -- additionally run a real authorized command through
      `AshA2A.CommandBus` and print `AshA2A.Semantic.Conformance.explain/1`'s
      real answers to the RFC S78 twelve questions for the resulting real
      receipt.
  """

  use Mix.Task

  alias AshA2A.Semantic.{Conformance, Profile}

  @switches [claim: :string, verbose: :boolean, explain: :boolean]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)

    claim = parse_claim(Keyword.get(opts, :claim))
    verbose? = Keyword.get(opts, :verbose, false)

    report = Conformance.report()

    print_requirements(report, verbose?)
    print_levels(report)
    print_invariants(report, verbose?)
    print_earned(report, claim)

    if Keyword.get(opts, :explain, false), do: print_explain()

    enforce_claim(report, claim)
  end

  defp parse_claim(nil), do: nil

  defp parse_claim(value) do
    case Profile.parse(value) do
      {:ok, level} ->
        level

      :error ->
        Mix.raise(
          "ash_a2a.verify_conformance: unknown --claim #{inspect(value)}; expected one of " <>
            Enum.map_join(Profile.levels(), ", ", &Profile.label/1)
        )
    end
  end

  # -- printing --

  defp print_requirements(report, verbose?) do
    Mix.shell().info("RFC S59 -- profile requirements (real executable checks)\n")

    Enum.each(Profile.levels(), fn level ->
      scoped = Enum.filter(report.requirements, &(&1.level == level))

      Mix.shell().info("#{Profile.label(level)}")
      Enum.each(scoped, &print_requirement(&1, verbose?))
      Mix.shell().info("")
    end)
  end

  defp print_requirement(%{status: :met} = requirement, verbose?) do
    Mix.shell().info("  MET           #{requirement.id}  (#{requirement.rfc_section})")
    if verbose?, do: Mix.shell().info(indent(requirement.detail))
  end

  defp print_requirement(%{status: :unmet} = requirement, _verbose?) do
    Mix.shell().error("  UNMET         #{requirement.id}  (#{requirement.rfc_section})")
    Mix.shell().info(indent(requirement.detail))
  end

  defp print_requirement(%{status: :unverifiable} = requirement, _verbose?) do
    Mix.shell().info("  UNVERIFIABLE  #{requirement.id}  (#{requirement.rfc_section})")
    Mix.shell().info(indent(requirement.detail))
  end

  defp print_levels(report) do
    Mix.shell().info("RFC S59 -- cumulative profile roll-up\n")

    Enum.each(report.levels, fn level ->
      verdict = if level.conformant?, do: "CONFORMANT", else: "NOT CONFORMANT"
      total = length(level.met) + length(level.unmet) + length(level.unverifiable)

      Mix.shell().info(
        "  #{String.pad_trailing(level.label, 12)} #{String.pad_trailing(verdict, 15)}" <>
          "#{length(level.met)}/#{total} met, #{length(level.unmet)} unmet, " <>
          "#{length(level.unverifiable)} unverifiable"
      )
    end)

    Mix.shell().info("")
  end

  defp print_invariants(report, verbose?) do
    Mix.shell().info("RFC S60 -- invariants\n")

    Enum.each(report.invariants, &print_invariant(&1, verbose?))
    Mix.shell().info("")
  end

  defp print_invariant(%{status: :ok} = invariant, verbose?) do
    Mix.shell().info("  HOLDS (#{invariant.scope})  #{invariant.formula}")
    if verbose?, do: Mix.shell().info(indent(invariant.detail))
  end

  defp print_invariant(%{status: :violated} = invariant, _verbose?) do
    Mix.shell().error("  VIOLATED          #{invariant.formula}")
    Mix.shell().info(indent(invariant.detail))
  end

  defp print_invariant(%{status: :unverifiable} = invariant, _verbose?) do
    Mix.shell().info("  UNVERIFIABLE      #{invariant.formula}")
    Mix.shell().info(indent(invariant.detail))
  end

  defp print_earned(report, claim) do
    earned =
      case report.earned_level do
        :none -> "none (SA2A-CORE is not fully met)"
        level -> Profile.label(level)
      end

    Mix.shell().info("Earned conformance level: #{earned}")

    case claim do
      nil -> Mix.shell().info("No --claim given: this run is a report, not a gate.")
      level -> Mix.shell().info("Claimed conformance level: #{Profile.label(level)}")
    end

    Mix.shell().info("")
  end

  defp print_explain do
    Mix.shell().info("RFC S78 -- the twelve questions, answered from one real receipt\n")

    case Conformance.explain_sample() do
      {:ok, answers} ->
        Enum.each(answers, &print_answer/1)
        coverage = Conformance.explain_coverage(answers)

        Mix.shell().info(
          "\n  #{coverage.answered} answered, #{coverage.partial} partial, " <>
            "#{coverage.unanswerable} unanswerable (of #{length(answers)})\n"
        )

      {:error, reason} ->
        Mix.shell().error("  could not produce a real receipt to explain: #{inspect(reason)}\n")
    end
  end

  defp print_answer(%{id: id, question: question, answer: answer}) do
    {label, body} =
      case answer do
        {:answered, value} -> {"ANSWERED    ", inspect(value, pretty: true, limit: :infinity)}
        {:partial, value, gap} -> {"PARTIAL     ", inspect(value, pretty: true) <> "\n" <> gap}
        {:unanswerable, reason} -> {"UNANSWERABLE", reason}
      end

    Mix.shell().info("  #{label}  #{id}: #{question}")
    Mix.shell().info(indent(body))
  end

  defp indent(text) do
    text
    |> to_string()
    |> String.split("\n")
    |> Enum.map_join("\n", &("                " <> &1))
  end

  # -- the gate --

  defp enforce_claim(_report, nil), do: :ok

  defp enforce_claim(report, level) do
    status = Conformance.level_status(level, report.requirements)
    violated = Enum.filter(report.invariants, &(&1.status == :violated))

    problems =
      Enum.map(status.unmet, &"UNMET #{&1.id}") ++
        Enum.map(status.unverifiable, &"UNVERIFIABLE #{&1.id}") ++
        Enum.map(violated, &"VIOLATED INVARIANT #{&1.id}")

    if problems == [] do
      Mix.shell().info(
        "ash_a2a.verify_conformance: claim #{Profile.label(level)} is really earned " <>
          "(#{length(status.met)}/#{length(status.met)} cumulative requirements met)."
      )
    else
      Mix.raise(
        "ash_a2a.verify_conformance: claimed #{Profile.label(level)} but #{length(problems)} " <>
          "requirement(s)/invariant(s) do not support it -- " <> Enum.join(problems, "; ")
      )
    end
  end
end
